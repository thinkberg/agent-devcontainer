#!/usr/bin/env -S python3 -I
# harness/harness.py — the safety harness engine: the Claude Code hooks,
# the agent's CLI and the operator's approval commands, in one program.
#
#   harness.py hook pre-bash              PreToolUse  Bash
#   harness.py hook pre-write             PreToolUse  Edit|Write|MultiEdit|NotebookEdit|Bash
#   harness.py hook post-write            PostToolUse Edit|Write|MultiEdit|NotebookEdit
#   harness.py hook stop-checks           Stop
#   harness.py hook ticket-state post|stop
#   harness.py status | steps | rules [--step NAME] [--json]
#   harness.py phase NAME [--ticket X] [--plan P] [--ponytail-reviewed]
#   harness.py approve PLAN [--scope GLOB…]        operator only (dcc approve)
#   harness.py approve-release REPO PR             operator only
#   harness.py check [--base REF]                  the gate's dry run
#
# Contract of a hook: JSON on stdin, JSON decision on stdout, exit 0. No
# output = no decision. A PostToolUse or Stop hook blocks with exit 2.
# The hooks fail closed: an unreadable registry, a corrupt overlay, a bad
# regex or a bug in this program denies. HARNESS_OFF (a root-owned marker,
# `dcc harness off`) makes every hook exit without a decision.
#
# Rules: the generic registry (rules.json next to this file) merged with
# the project overlay (<root>/.devcontainer/rules/rules.json). State:
# HARNESS_AGENT_DIR/run.json (agent-writable), approval tokens in
# HARNESS_APPROVAL_DIR (root-only in the container).
#
# Standard library only; syntax no newer than Python 3.9 (macOS hosts run
# the tests with the system python3). subprocess/tempfile/datetime/hashlib
# are imported where used: the common hook path spawns nothing and starts
# fast. `python3 -I`: no user site-packages, no PYTHON* variables — the
# agent could write a .pth file into its own site-packages otherwise, and
# that would run inside every hook.
import fnmatch
import json
import os
import re
import sys

AGENT = os.environ.get("HARNESS_AGENT_DIR", "/run/harness/agent")            # agent-writable run state
APPROV = os.environ.get("HARNESS_APPROVAL_DIR", "/run/harness/approvals")    # root-only: operator tokens
OFF = os.environ.get("HARNESS_OFF", "/run/harness/off")                      # operator's switch
HERE = os.path.dirname(os.path.realpath(__file__))
GENERIC_RULES = os.environ.get("HARNESS_RULES", os.path.join(HERE, "rules.json"))
CHECKERS = os.path.join(HERE, "checkers")
CHECK_TIMEOUT = int(os.environ.get("HARNESS_CHECK_TIMEOUT", "60"))
ROOT = ""            # absolute workspace root, set by every entry point
PROJECT_RULES = ""   # the overlay; set with ROOT
PROJECT_DIR = ""
RULES = None         # the merged registry (dict), or None = unreadable (fail closed)
MERGED_FILE = None   # the merged registry on disk, written for checkers on first use


def harness_off():
    return os.path.exists(OFF)


# ---- registry ----------------------------------------------------------------

REGEX_KEYS = {"regex", "when", "dirty_on", "clean_on", "ticket_regex"}


def _compile_all(node):
    """Compile every regex string in the registry; a bad one raises re.error."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k in REGEX_KEYS:
                for rx in (v if isinstance(v, list) else [v]):
                    if isinstance(rx, str):
                        re.compile(rx)
            else:
                _compile_all(v)
    elif isinstance(node, list):
        for v in node:
            _compile_all(v)


def _deep_merge(a, b):
    out = dict(a)
    for k, v in b.items():
        out[k] = _deep_merge(out[k], v) if isinstance(out.get(k), dict) and isinstance(v, dict) else v
    return out


def load_rules():
    """The project overlay merged over the generic registry, or None.
    Fails closed: an unreadable registry, a corrupt overlay or a regex that
    does not compile leaves RULES None (stricter than the shell engine, where
    grep failed open on a bad regex)."""
    try:
        with open(GENERIC_RULES, encoding="utf-8") as fh:
            g = json.load(fh)
        if os.path.isfile(PROJECT_RULES):
            with open(PROJECT_RULES, encoding="utf-8") as fh:
                p = json.load(fh)
            off = set(p.get("disabled") or [])
            pr = p.get("rules") or []
            by_id = {r["id"]: r for r in pr}
            generic_ids = {r["id"] for r in g["rules"]}
            rules = [by_id.get(r["id"], r) for r in g["rules"] if r["id"] not in off]
            rules += [r for r in pr if r["id"] not in generic_ids]
            for r in rules:
                if r["id"] == "protected-paths":
                    c = r.setdefault("check", {})
                    c["paths"] = c.get("paths", []) + (p.get("protected_paths") or [])
            merged = {"steps": g.get("steps"), "version": g.get("version"),
                      "phases": _deep_merge(g.get("phases") or {}, p.get("phases") or {}),
                      "project": p.get("project") or {}, "rules": rules}
        else:
            merged = g
        _compile_all(merged)
        return merged
    except (OSError, ValueError, KeyError, TypeError, AttributeError, re.error):
        return None


def set_root(root):
    global ROOT, PROJECT_RULES, PROJECT_DIR, RULES
    ROOT = os.path.realpath(root)
    PROJECT_RULES = os.environ.get("HARNESS_PROJECT_RULES", os.path.join(ROOT, ".devcontainer", "rules", "rules.json"))
    PROJECT_DIR = os.path.dirname(PROJECT_RULES)
    RULES = load_rules()


def rule(rid):
    return next((r for r in RULES["rules"] if r["id"] == rid), None)


def rule_active(rid):
    r = rule(rid)
    return r is not None and r.get("class") == "enforce"


def rules_with_trigger(name):
    out = []
    for r in RULES["rules"]:
        t = r.get("trigger")
        if r.get("class") == "advise" or t is None:
            continue
        if name in (t if isinstance(t, list) else [t]):
            out.append(r)
    return out


def check(r):
    return r.get("check") or {}


def as_list(v):
    return v if isinstance(v, list) else [v]


# ---- grep semantics: line-based, like `grep -E` on the command ---------------

def grep(rx, text, icase=False):
    c = re.compile(rx, re.I if icase else 0)
    return any(c.search(line) for line in text.split("\n"))


def grep_o(rx, text):
    """every match, like `grep -oE`"""
    c = re.compile(rx)
    return [m.group(0) for line in text.split("\n") for m in c.finditer(line)]


def glob_match(path, pattern):
    """bash [[ $path == $pattern ]]: `*` also matches `/`"""
    return fnmatch.fnmatchcase(path, pattern)


# ---- plan blob, tokens, phase ------------------------------------------------

def blob_of(path):
    """The git blob id of the file as it is on disk (no git needed); empty when
    unreadable. Equals `git rev-parse HEAD:<path>` for a clean file."""
    import hashlib
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return ""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def git(cwd, *args):
    """stdout of a git command, or None on failure"""
    import subprocess
    try:
        r = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True)
    except OSError:
        return None
    return r.stdout.rstrip("\n") if r.returncode == 0 else None


def committed_blob(rel):
    """The committed blob hash of the plan, or empty when it is not committed
    or has uncommitted changes. Operator time only (phase, approve, status)."""
    repo = git(os.path.join(ROOT, os.path.dirname(rel)), "rev-parse", "--show-toplevel")
    if not repo:
        return ""
    in_repo = os.path.join(ROOT, rel)
    if in_repo.startswith(repo + "/"):
        in_repo = in_repo[len(repo) + 1:]
    if git(repo, "status", "--porcelain", "--", in_repo):
        return ""
    return git(repo, "rev-parse", "--verify", "-q", "HEAD:" + in_repo) or ""


def approval_token(plan):
    return os.path.join(APPROV, os.path.basename(plan or "none") + ".approved")


def token_blob(path):
    """the token is JSON {blob, scope[]}; older tokens hold the bare blob"""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return ""
    try:
        return json.loads(text).get("blob") or ""
    except (ValueError, AttributeError):
        return text.rstrip("\n")


def token_scope(path):
    try:
        with open(path, encoding="utf-8") as fh:
            scope = json.load(fh).get("scope") or []
    except (OSError, ValueError, AttributeError):
        return []
    return scope or ["*"]


def run_state():
    try:
        with open(os.path.join(AGENT, "run.json"), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def effective_phase():
    """the declared phase; `implement` holds only while the operator's token
    matches the plan on disk. No state at all = brainstorm (fail closed)."""
    st = run_state()
    if st is None:
        return "brainstorm"
    p = st.get("phase") or "brainstorm"
    if p == "implement":
        plan = st.get("plan") or ""
        tok = approval_token(plan)
        if not (plan and os.path.isfile(tok) and token_blob(tok) == blob_of(os.path.join(ROOT, plan))):
            return "review"
    return p


def implement_scope():
    st = run_state() or {}
    return token_scope(approval_token(st.get("plan") or ""))


# ---- checkers ----------------------------------------------------------------

def run_checker(template, rel, stdin):
    """(rc, stdout) of a checker; placeholders substituted per argument.
    A timeout or a missing program is an error (rc 3)."""
    import shlex
    import subprocess
    global MERGED_FILE
    if MERGED_FILE is None:   # checkers read the merged registry from HARNESS_RULES
        import atexit
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as t:
            json.dump(RULES, t)
            path = MERGED_FILE = t.name
        atexit.register(lambda: os.path.exists(path) and os.unlink(path))
        os.environ["HARNESS_RULES"] = path
    sub = {"{checkers}": CHECKERS, "{project}": PROJECT_DIR, "{root}": ROOT, "{file}": rel, "{repo}": rel.split("/")[0]}
    argv = []
    for tok in shlex.split(template):
        for k, v in sub.items():
            tok = tok.replace(k, v)
        if tok:
            argv.append(tok)
    try:
        r = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, timeout=CHECK_TIMEOUT)
    except subprocess.TimeoutExpired:
        return 3, "checker timed out"
    except OSError as e:
        return 3, "checker could not start: %s" % e
    return r.returncode, r.stdout.decode("utf-8", "replace").rstrip("\n")


def explain(rc):
    return {1: "violation", 2: "approval needed"}.get(rc, "check could not run (exit %d) — treated as a failure" % rc)


def one_line(s):
    return s.replace("\n", "; ")


# ---- hook plumbing -----------------------------------------------------------

def hook_input():
    raw = sys.stdin.buffer.read()
    try:
        inp = json.loads(raw)
    except ValueError:
        inp = {}
    return inp if isinstance(inp, dict) else {}, raw


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}))
    sys.exit(0)


def hook_root(inp):
    return os.environ.get("CLAUDE_PROJECT_DIR") or inp.get("cwd") or "."


def state_dir():
    """session state: the agent dir when writable, else a per-user temp dir"""
    if os.path.isdir(AGENT) and os.access(AGENT, os.W_OK):
        return AGENT
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp", "harness-session")


def touched_file(sid):
    return os.path.join(AGENT, sid + ".touched")


def note_touched(sid, rel):
    try:
        os.makedirs(AGENT, exist_ok=True)
        with open(touched_file(sid), "a", encoding="utf-8") as fh:
            fh.write(rel + "\n")
    except OSError:
        pass


# ---- hook: pre-bash ----------------------------------------------------------

MUTATING = "add|commit|push|mv|rm|reset|rebase|merge|checkout|switch|tag|stash|cherry-pick|revert|restore|clean|am|apply"


def hook_pre_bash():
    """Denies the command when an `enforce` rule with trigger pre_bash matches.
    First match wins; the rule id is in the reason. Regexes are line-based and
    not quote-aware — a false deny costs one retry, a false allow an incident."""
    inp, raw = hook_input()
    cmd = (inp.get("tool_input") or {}).get("command") or ""
    if not cmd:
        return
    set_root(hook_root(inp))
    if RULES is None:
        deny("harness [harness-registry]: rule registry unreadable or overlay corrupt (generic: %s, project: %s)"
             % (os.environ.get("HARNESS_RULES", "default"), PROJECT_RULES))

    # builtin git-c-absolute: every mutating git carries -C /absolute/path;
    # a relative -C is refused too (the incident was a cd that did not persist)
    if rule_active("git-c-absolute"):
        for occ in grep_o(r"\bgit(\s+-[cC]\s+\S+)*\s+(%s)\b" % MUTATING, cmd):
            if not re.search(r"\s-C\s+/", occ):
                deny("harness [git-c-absolute]: mutating git without -C /absolute/path in '%s' — "
                     "name the repo explicitly, a cd does not persist between calls" % occ)

    # checker-backed rules: `when` selects the command, the checker decides
    for r in rules_with_trigger("pre_bash"):
        c = check(r)
        if c.get("run") and c.get("when") and grep(c["when"], cmd):
            rc, out = run_checker(c["run"], "", raw)
            if rc != 0:
                deny("harness [%s]: %s: %s — %s" % (r["id"], explain(rc), one_line(out), r.get("text", "")))

    # data-driven regex rules
    for r in rules_with_trigger("pre_bash"):
        c = check(r)
        if not c.get("regex"):
            continue
        if c.get("when") and not grep(c["when"], cmd):
            continue
        for rx in as_list(c["regex"]):
            if rx and grep(rx, cmd, icase=bool(c.get("icase"))):
                deny("harness [%s]: %s" % (r["id"], r.get("text", "")))


# ---- hook: pre-write ---------------------------------------------------------
# Denies writes to the paths of the `protected-paths` rule, and — the phase
# gate — writes the current phase does not permit. Globs are workspace-
# relative (`*` also matches `/`) or absolute when they start with `/`. For
# Bash the check is a heuristic: the write targets of the command (redirects,
# the file arguments of writing commands). The guarantee is the read-only
# bind mount; this hook is the early feedback.

HEREDOC = re.compile(r"(^|[^<])<<-?[ \t]*[\"']?([A-Za-z_][A-Za-z0-9_]*)")


def strip_heredocs(cmd):
    """heredoc bodies are data, not commands: drop them, or a markdown `> quote`
    or a `mv` in prose becomes a write target.
    ponytail: first heredoc per line only; a second one on the same line is
    parsed as commands"""
    out, term = [], None
    for line in cmd.split("\n"):
        if term is not None:
            if line == term or re.match(r"^\t*" + re.escape(term) + "$", line):
                term = None
            continue
        out.append(line)
        m = HEREDOC.search(line)
        if m:
            term = m.group(2)
    return "\n".join(out)


SEP = "\x01"   # marks a control operator (| || ; && and newline) in words()


def words(s):
    """one word per item, quotes and backslashes resolved as far as a path
    needs; SEP marks a control operator. A lone & (background) stays in its
    word — >&1 and &> need it."""
    out, w, inw, q, i, n = [], [], False, None, 0, len(s)

    def emit():
        nonlocal w, inw
        if inw:
            out.append("".join(w))
        w, inw = [], False

    while i < n:
        c, nx = s[i], s[i + 1:i + 2]
        if q:
            if c == q:
                q = None
            elif q == '"' and c == "\\" and nx in ('"', "\\", "$", "`"):
                w.append(nx)
                i += 1
            else:
                w.append(c)
        elif c in "'\"":
            q, inw = c, True
        elif c == "\\":
            if nx != "\n":
                w.append(nx)
            inw = inw or nx != "\n"
            i += 1
        elif c in " \t":
            emit()
        elif c == "&" and nx != "&":
            w.append(c)
            inw = True
        elif c in "\n;|&":
            emit()
            out.append(SEP)
            if nx == c:
                i += 1
        else:
            w.append(c)
            inw = True
        i += 1
    emit()
    return out


WRITERS = {"tee", "truncate", "touch", "chmod", "chown", "mkdir", "rm", "rmdir", "mv", "dd"}
LAST_IS_TARGET = {"cp", "rsync", "install", "ln"}    # sources are reads
WRAPPERS = {"sudo", "env", "nice", "timeout"}


def judge_segment(seg):
    """one simple command -> its write targets: redirect destinations (> f,
    >> f, 1> f, &> f; not 2> f, not >&1) and the file arguments of commands
    that write, move or delete"""
    targets, w, i = [], [], 0
    while i < len(seg):
        x = seg[i]
        if x.startswith("2>"):
            pass
        elif x in (">", ">>", "1>", "1>>", "&>", "&>>"):
            targets.append(seg[i + 1] if i + 1 < len(seg) else "")
            i += 1
        elif x.startswith((">", "1>", "&>")):            # attached: >file
            c = x[1:] if x[0] in "1&" else x
            for lead in (">", ">", "|"):
                if c.startswith(lead):
                    c = c[1:]
            if c and not c.startswith("&"):
                targets.append(c)
        else:
            w.append(x)
        i += 1
    if not w:
        return targets
    c, args = os.path.basename(w[0]), w[1:]
    while c in WRAPPERS and args:                        # peel wrappers
        c, args = os.path.basename(args[0]), args[1:]
        while args and (args[0].startswith("-") or ("=" in args[0] and c == "env")):
            args = args[1:]
    mode = "all"
    if c == "sed":
        if not re.search(r"(^|\s)(-[a-zA-Z]*i|--in-place)", " ".join(args)):   # only in-place
            return targets
        # the script is not a file: explicit after -e/-f, else the first bare word
        n, skip, expl = [], False, False
        for a in args:
            if skip:
                skip = False
                continue
            if a in ("-e", "--expression", "-f", "--file"):
                skip = expl = True
            elif a.startswith(("--expression=", "--file=")):
                expl = True
            elif a.startswith("-"):
                pass
            else:
                n.append(a)
        args = n if expl else n[1:]
    elif c in WRITERS:
        pass
    elif c in LAST_IS_TARGET:
        mode = "last"
    elif c == "git":   # skip -C/-c and their values; the first bare word is the subcommand
        n, skip, cdir, sub = [], None, "", ""
        for a in args:
            if skip:
                if skip == "C":
                    cdir = a
                skip = None
                continue
            if a == "-C":
                skip = "C"
            elif a == "-c":
                skip = "c"
            elif a.startswith("-"):
                pass
            elif not sub:
                sub = a
            else:
                n.append(a)
        if sub not in ("mv", "rm"):
            return targets
        args = [cdir + "/" + a if cdir and not a.startswith("/") else a for a in n]   # relative to -C
    else:
        return targets
    files = [a for a in args if not a.startswith("-")]
    if files:
        targets += [files[-1]] if mode == "last" else files
    return targets


def write_targets(cmd):
    targets, seg = [], []
    for wd in words(strip_heredocs(cmd)):
        if wd == SEP:
            targets += judge_segment(seg)
            seg = []
        else:
            seg.append(wd)
    targets += judge_segment(seg)
    # ponytail: an unexpanded $VAR or `…` is the shell's to resolve, not ours —
    # skipped; the read-only mounts are the guarantee
    return [t for t in targets if t and not t.startswith("-") and "$" not in t and "`" not in t]


def hook_pre_write():
    inp, _ = hook_input()
    tool = inp.get("tool_name") or ""
    cwd = inp.get("cwd") or ""
    root = os.environ.get("CLAUDE_PROJECT_DIR") or cwd
    if not root:
        return
    set_root(root)
    if RULES is None:
        deny("harness [harness-registry]: rule registry unreadable or overlay corrupt")
    pp = rule("protected-paths")
    globs = check(pp).get("paths", []) if pp and pp.get("class") == "enforce" else []
    phase, always, allow = None, [], []
    if rule_active("phase-gate"):
        phases = RULES.get("phases") or {}
        phase = effective_phase()
        always = phases.get("always_allow") or []
        # implement: the approval's scope PLUS what review already allowed —
        # approval widens the writable set, never narrows it
        if phase == "implement":
            allow = implement_scope() + ((phases.get("allow_write") or {}).get("review") or [])
        else:
            allow = (phases.get("allow_write") or {}).get(phase) or []
    if not globs and phase is None:
        return
    sid = inp.get("session_id") or "nosession"

    def deny_phase(rel):
        order = (RULES.get("phases") or {}).get("order") or []
        i = order.index(phase) if phase in order else -1
        nxt = order[i + 1] if 0 <= i and i + 1 < len(order) else phase
        allowed = "".join(g + " " for g in allow) or " "
        if phase == "implement":
            deny("harness [scope-to-project]: the approved scope is %s— %s is outside it; "
                 "ask the operator to widen it (dcc approve <plan> --scope …)" % (allowed, rel))
        deny("harness [phase-gate]: phase %s allows writes only to %s— %s is outside. "
             "Next: harness phase %s (see harness status)" % (phase, allowed, rel, nxt))

    def resolve(p):
        abs_ = os.path.realpath(p if p.startswith("/") else os.path.join(cwd or ROOT, p))
        rel = abs_[len(ROOT) + 1:] if abs_.startswith(ROOT + "/") else abs_
        return abs_, rel

    def real_path(abs_):   # a sed expression like s/a/b/ looks like a path and is not one
        return os.path.exists(abs_) or os.path.isdir(os.path.dirname(abs_))

    def check_path(p):
        if not p:
            return
        abs_, rel = resolve(p)
        for g in globs:
            if g.startswith("/"):
                if glob_match(abs_, g):
                    deny("harness [protected-paths]: %s is read-only for the agent (matches %s)" % (abs_, g))
            elif rel != abs_ and glob_match(rel, g):
                deny("harness [protected-paths]: %s is read-only for the agent (matches %s)" % (rel, g))
        # phase gate: paths inside the workspace; for Bash tokens only real paths
        if phase is not None and rel != abs_ and (tool != "Bash" or real_path(abs_)):
            if any(glob_match(abs_, g) or glob_match(rel, g) for g in always):
                return
            if any(glob_match(rel, g) for g in allow):
                return
            deny_phase(rel)

    def touched(p):   # remember what this session wrote, for the Stop-time checks
        abs_, rel = resolve(p)
        if rel != abs_ and real_path(abs_):
            note_touched(sid, rel)

    ti = inp.get("tool_input") or {}
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        f = ti.get("file_path") or ti.get("notebook_path") or ""
        check_path(f)
        if f:
            touched(f)
    elif tool == "Bash":
        for tok in write_targets(ti.get("command") or ""):
            check_path(tok)
            touched(tok)


# ---- hook: post-write --------------------------------------------------------

def hook_post_write():
    """Runs every post_write rule whose `paths` match the edited file. The edit
    has happened: findings go back on stderr with exit 2 (feedback, not a block)."""
    inp, raw = hook_input()
    ti = inp.get("tool_input") or {}
    f = ti.get("file_path") or ti.get("notebook_path") or ""
    if not f:
        return
    set_root(hook_root(inp))
    if RULES is None:
        print("harness [harness-registry]: rule registry unreadable or overlay corrupt", file=sys.stderr)
        sys.exit(2)
    abs_ = os.path.realpath(f)
    if not abs_.startswith(ROOT + "/"):
        return
    rel = abs_[len(ROOT) + 1:]
    note_touched(inp.get("session_id") or "nosession", rel)
    msgs = ""
    for r in rules_with_trigger("post_write"):
        c = check(r)
        if not (c.get("run") and c.get("paths")):
            continue
        if not any(glob_match(rel, g) for g in c["paths"]):
            continue
        rc, out = run_checker(c["run"], rel, raw)
        if rc != 0:
            msgs += "harness [%s]: %s\n%s\n" % (r["id"], explain(rc), out)
    if msgs:
        sys.stderr.write(msgs)
        sys.exit(2)


# ---- hook: stop-checks -------------------------------------------------------

def hook_stop_checks():
    """Runs every rule with trigger stop and a check.run; a rule with `paths`
    only when this session wrote a matching file. enforcement "block": a
    violation blocks the stop (exit 2, once per session per rule — a ceiling
    so a session cannot loop); "warn": a systemMessage, the stop proceeds."""
    inp, raw = hook_input()
    sid = inp.get("session_id") or "nosession"
    set_root(hook_root(inp))
    if RULES is None:
        print("harness [harness-registry]: rule registry unreadable or overlay corrupt", file=sys.stderr)
        sys.exit(2)
    state = state_dir()
    os.makedirs(state, exist_ok=True)
    try:
        with open(touched_file(sid), encoding="utf-8") as fh:
            touched = sorted({l for l in fh.read().split("\n") if l})
    except OSError:
        touched = []
    block, warn = "", ""
    for r in rules_with_trigger("stop"):
        c = check(r)
        if not c.get("run"):
            continue
        # a rule with `paths` binds only when this session wrote a matching file;
        # pre-existing findings are the gate's business (dcc check)
        if c.get("paths") and not any(glob_match(t, g) for g in c["paths"] for t in touched):
            continue
        rc, out = run_checker(c["run"], "", raw)
        if rc == 0:
            continue
        line = "harness [%s]: %s — %s\n" % (r["id"], explain(rc), one_line(out))
        marker = os.path.join(state, "%s.stop-%s" % (sid, r["id"]))
        if r.get("enforcement", "warn") == "block" and not os.path.isfile(marker):
            open(marker, "a").close()
            block += line
        else:
            warn += line
    if block:
        sys.stderr.write(block + warn + "These concern what this session changed. Fix them before finishing, "
                         "or say why you cannot (each blocks once; the gate refuses the run regardless).\n")
        sys.exit(2)
    if warn:
        print(json.dumps({"systemMessage": warn[:-1]}))


# ---- hook: ticket-state ------------------------------------------------------

def hook_ticket_state(mode):
    """A completion rule with state (check-tickets-after-change). post: a
    ticket-mutating command marks the session dirty, a clean check-tickets run
    clears it. stop: a dirty session may not end (exit 2), up to max_blocks
    times — past that the stop goes through with a loud message."""
    inp, _ = hook_input()
    sid = inp.get("session_id") or "nosession"
    set_root(hook_root(inp))
    if RULES is None:
        return
    r = rule("check-tickets-after-change")
    if r is None:
        return
    c = check(r)
    state = state_dir()
    try:
        os.makedirs(state, exist_ok=True)
    except OSError:
        return
    dirty = os.path.join(state, sid + ".ticket-dirty")
    blocks = os.path.join(state, sid + ".ticket-blocks")
    if mode == "post":
        if inp.get("tool_name") != "Bash":
            return
        cmd = (inp.get("tool_input") or {}).get("command") or ""
        if grep(c.get("clean_on", ""), cmd):
            # PostToolUse fires on success only; a failing check-tickets lands in PostToolUseFailure
            for p in (dirty, blocks):
                if os.path.exists(p):
                    os.unlink(p)
        elif grep(c.get("dirty_on", ""), cmd):
            with open(dirty, "w", encoding="utf-8") as fh:
                fh.write(utc_now() + "\n")
    elif mode == "stop":
        if not os.path.isfile(dirty):
            return
        try:
            with open(blocks, encoding="utf-8") as fh:
                n = int(fh.read().strip() or 0) + 1
        except (OSError, ValueError):
            n = 1
        with open(blocks, "w", encoding="utf-8") as fh:
            fh.write("%d\n" % n)
        mx = int(c.get("max_blocks") or 3)
        if n <= mx:
            with open(dirty, encoding="utf-8") as fh:
                since = fh.read().rstrip("\n")
            print("harness [check-tickets-after-change]: tickets changed in this session (since %s) and "
                  "bin/check-tickets has not run clean since. Run extracarts-planning/bin/check-tickets, "
                  "fix or flag its findings, then finish. (%d/%d)" % (since, n, mx), file=sys.stderr)
            sys.exit(2)
        print(json.dumps({"systemMessage": "harness [check-tickets-after-change]: stop allowed after %d blocks — "
                          "bin/check-tickets still has not run clean; the gate will refuse this run" % n}))
    else:
        die("usage: harness hook ticket-state post|stop")


# ---- the CLI -----------------------------------------------------------------

def die(msg):
    print("harness: " + msg, file=sys.stderr)
    sys.exit(1)


def find_root():
    """nearest ancestor with .devcontainer/devcontainer.json, like dcc; else the cwd"""
    d = cwd = os.getcwd()
    while not os.path.isfile(os.path.join(d, ".devcontainer", "devcontainer.json")):
        if d == "/":
            return cwd
        d = os.path.dirname(d)
    return d


def state(key):
    return (run_state() or {}).get(key) or ""


def utc_now():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cli_status():
    if harness_off():
        print("harness: OFF — the operator switched it off (dcc harness off); hooks make no decisions "
              "until 'dcc harness on' or the next container start")
    else:
        print("harness: on")
    print("rules:  %d (%s)" % (len(RULES["rules"]), (RULES.get("project") or {}).get("name") or "no project overlay"))
    print("phase:  %s  effective: %s" % (state("phase") or "brainstorm (no run state)", effective_phase()))
    print("ticket: %s" % state("ticket"))
    plan = state("plan")
    print("plan:   %s" % plan)
    if plan:
        blob = committed_blob(plan)
        print("plan committed blob: %s" % (blob or "NO (uncommitted or dirty)"))
        tok = approval_token(plan)
        if os.path.isfile(tok):
            if token_blob(tok) == blob:
                print("approval: valid  scope: %s" % "".join(s + " " for s in token_scope(tok)))
            else:
                print("approval: STALE (plan changed after approval)")
        else:
            print("approval: none")


def cli_phase(argv):
    if not argv:
        die("usage: harness phase <name> [--ticket X] [--plan P] [--ponytail-reviewed]")
    target, argv = argv[0], argv[1:]
    phases = RULES["phases"]
    order = phases["order"]
    if target not in order:
        die("unknown phase '%s'" % target)
    ticket, plan, ponytail = state("ticket"), state("plan"), state("ponytail_reviewed")
    while argv:
        if argv[0] == "--ticket" and len(argv) > 1:
            ticket, argv = argv[1], argv[2:]
        elif argv[0] == "--plan" and len(argv) > 1:
            plan, argv = argv[1], argv[2:]
        elif argv[0] == "--ponytail-reviewed":
            ponytail, argv = True, argv[1:]
        else:
            die("unknown option %s" % argv[0])
    idx = order.index
    blob = ""
    if idx(target) >= idx("plan"):
        if not re.search(phases["ticket_regex"], ticket or ""):
            die("phase %s needs a ticket (--ticket backend#12); %s" % (target, phases["preconditions"]["plan"]))
    if idx(target) >= idx("review"):
        glob = phases["plan_glob"]
        if not plan:
            die("phase %s needs --plan <path> under %s" % (target, glob))
        if plan.startswith(ROOT + "/"):
            plan = plan[len(ROOT) + 1:]
        if not glob_match(plan, glob):
            die("plan '%s' is not under %s" % (plan, glob))
        if not os.path.isfile(os.path.join(ROOT, plan)):
            die("plan file %s does not exist" % plan)
        blob = committed_blob(plan)
        if not blob:
            die("plan %s is not committed, or has uncommitted changes — commit it first (explicit path, -C absolute)" % plan)
        if ponytail not in (True, "true"):
            die("phase %s needs --ponytail-reviewed: run ponytail-review over %s, fold the trims in, commit, "
                "then declare it" % (target, plan))
    if target == "implement":
        tok = approval_token(plan)
        if not os.path.isfile(tok):
            die("phase implement needs the operator's approval: ask for 'dcc approve %s' on the host" % plan)
        if token_blob(tok) != blob:
            die("approval is stale: %s changed after it was approved — ask for a new 'dcc approve %s'" % (plan, plan))
    os.makedirs(AGENT, exist_ok=True)
    with open(os.path.join(AGENT, "run.json"), "w", encoding="utf-8") as fh:
        json.dump({"phase": target, "ticket": ticket or "", "plan": plan or "",
                   "ponytail_reviewed": ponytail in (True, "true"), "since": utc_now()}, fh)
        fh.write("\n")
    print("phase: %s%s%s" % (target, "  ticket: " + ticket if ticket else "", "  plan: " + plan if plan else ""))


def cli_approve(argv):
    if not argv:
        die("usage: harness approve <plan-path> [--scope <glob> ...]")
    plan, argv = argv[0], argv[1:]
    if plan.startswith(ROOT + "/"):
        plan = plan[len(ROOT) + 1:]
    scope = argv[1:] if argv[:1] == ["--scope"] else []
    blob = committed_blob(plan)
    if not blob:
        die("plan %s is not committed (or dirty) — nothing to approve" % plan)
    os.makedirs(APPROV, exist_ok=True)
    with open(approval_token(plan), "w", encoding="utf-8") as fh:
        json.dump({"blob": blob, "scope": scope or ["*"]}, fh)
        fh.write("\n")
    print("approved %s at blob %s, scope: %s" % (plan, blob, " ".join(scope) or "*"))


def cli_approve_release(argv):
    if len(argv) < 2:
        die("usage: harness approve-release <repo-dir> <pr>")
    import subprocess
    repo, pr = argv[0], argv[1]
    try:
        r = subprocess.run(["gh", "pr", "view", pr, "--json", "headRefOid,baseRefName"], cwd=repo,
                           capture_output=True, text=True)
        head = json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, ValueError):
        head = None
    if not head:
        die("cannot read PR %s in %s" % (pr, repo))
    if head.get("baseRefName") != "production":
        die("PR %s does not target production" % pr)
    os.makedirs(APPROV, exist_ok=True)
    sha = head.get("headRefOid") or ""
    with open(os.path.join(APPROV, "release-%s-%s.approved" % (os.path.basename(os.path.realpath(repo)), pr)),
              "w", encoding="utf-8") as fh:
        fh.write(sha)
    print("approved release PR %s at %s" % (pr, sha[:7]))


def cli_steps():
    phases = RULES["phases"]
    cur, declared = effective_phase(), state("phase")
    print("The working process — current phase: %s%s" % (cur, " (declared: %s)" % declared if declared else ""))
    print()
    for ph in phases["order"]:
        print("%s %-11s writes: %s" % ("▶" if ph == cur else " ", ph, " ".join((phases.get("allow_write") or {}).get(ph) or [])))
        pre = (phases.get("preconditions") or {}).get(ph)
        if pre:
            print("  %-11s enter with: %s" % ("", pre))
    print()
    print("  brainstorm → plan → review → implement: the agent advances with 'harness phase <name>';")
    print("  review → implement needs the operator's token (dcc approve <plan> [--scope …] on the host).")
    print("  After implement the steps verify, commit, publish, release, close are rule-guarded: 'harness rules --step <name>'.")
    print("  Rule steps: %s" % " ".join(RULES.get("steps") or []))


def mechanism(r):
    c = check(r)
    if c.get("builtin"):
        return "hook:" + c["builtin"]
    if c.get("regex"):
        return "hook:regex"
    if c.get("paths") and not c.get("run"):
        return "hook:paths"
    if c.get("run"):
        return "checker"
    if c.get("dirty_on"):
        return "hook:stop"
    return r.get("status") or "prose"


def cli_rules(argv):
    if argv[:1] == ["--json"]:
        print(json.dumps(RULES, indent=2, ensure_ascii=False))
        return
    step = ""
    if argv[:1] == ["--step"]:
        if len(argv) < 2:
            die("usage: harness rules [--step <name>]")
        step = argv[1]
    fmt = "%-10s %-8s %-28s %-22s %s"
    print(fmt % ("STEP", "CLASS", "RULE", "MECHANISM", "TEXT"))
    rows = sorted((r.get("step", ""), r.get("class", ""), r["id"], mechanism(r), (r.get("text") or "")[:80])
                  for r in RULES["rules"] if not step or r.get("step") == step)
    for row in rows:
        print(fmt % row)


def workspace_files():
    """every workspace file, hidden entries and node_modules pruned.
    ponytail: one walk per gate run; switch to git ls-files per repo if a
    workspace makes this slow"""
    out = []
    for d, dirs, files in os.walk(ROOT):
        dirs[:] = sorted(x for x in dirs if not x.startswith(".") and x != "node_modules")
        for f in sorted(files):
            if not f.startswith(".") and f != "node_modules":
                out.append(os.path.relpath(os.path.join(d, f), ROOT))
    return out


def cli_check(argv):
    """the gate's dry run: every rule with trigger `gate`. A per-file rule
    ({file} in its template) runs once for every workspace file its `paths`
    match and reports the worst result (error > violation > approval)."""
    base = argv[1] if argv[:1] == ["--base"] and len(argv) > 1 else ""
    files = None
    rc = 0

    def gate_files(run, globs):
        nonlocal files
        if not globs:
            return 3, "per-file rule without check.paths"
        if files is None:
            files = workspace_files()
        n, worst, lines = 0, 0, []
        for rel in files:
            if any(glob_match(rel, g) for g in globs):
                n += 1
                c, o = run_checker(run, rel, b"")
                if c != 0:
                    lines.append(o)          # only findings, not the chatter of passing files
                worst = max(worst, {0: 0, 1: 2, 2: 1}.get(c, 3))
        lines.append("(%d files)" % n)
        return {0: 0, 1: 2, 2: 1, 3: 3}[worst], "\n".join(lines)

    for r in rules_with_trigger("gate"):
        c = check(r)
        if not c.get("run"):
            continue
        run = c["run"] + (" --base " + base if base else "")
        if "{file}" in run:
            crc, out = gate_files(run, c.get("paths") or [])
        else:
            crc, out = run_checker(run, "", b"")
        label = {0: "ok   ", 1: "FAIL ", 2: "NEEDS"}.get(crc, "ERROR")
        print("  %s %-26s %s" % (label, r["id"], one_line(out)))
        if crc != 0:
            rc = 1
    sys.exit(rc)


USAGE = ("usage: harness status | steps | rules [--step <name>] | phase <name> [opts] | approve <plan> [--scope g…] | "
         "approve-release <repo> <pr> | check [--base REF] | hook <name>")


def main(argv):
    if argv[:1] == ["hook"]:
        if harness_off():   # the operator's switch: no decisions at all
            return 0
        name = argv[1] if len(argv) > 1 else ""
        if name == "pre-bash":
            hook_pre_bash()
        elif name == "pre-write":
            hook_pre_write()
        elif name == "post-write":
            hook_post_write()
        elif name == "stop-checks":
            hook_stop_checks()
        elif name == "ticket-state":
            hook_ticket_state(argv[2] if len(argv) > 2 else "")
        else:
            die("usage: harness hook pre-bash|pre-write|post-write|stop-checks|ticket-state post|stop")
        return 0
    verb = argv[0] if argv else ""
    if verb not in ("status", "steps", "rules", "phase", "approve", "approve-release", "check"):
        die(USAGE)
    set_root(os.environ.get("CLAUDE_PROJECT_DIR") or find_root())
    if RULES is None:
        die("rule registry unreadable or project overlay corrupt (generic: %s, project: %s)" % (GENERIC_RULES, PROJECT_RULES))
    {"status": lambda a: cli_status(), "steps": lambda a: cli_steps(), "rules": cli_rules, "phase": cli_phase,
     "approve": cli_approve, "approve-release": cli_approve_release, "check": cli_check}[verb](argv[1:])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]) or 0)
    except SystemExit:
        raise
    except Exception as e:   # a bug in the engine must not fail open
        msg = "harness [harness-engine]: %s: %s" % (type(e).__name__, e)
        if sys.argv[1:3] in (["hook", "pre-bash"], ["hook", "pre-write"]):
            deny(msg + " (fail closed)")      # PreToolUse: a non-zero exit would not block
        print(msg, file=sys.stderr)
        sys.exit(2 if sys.argv[1:2] == ["hook"] else 1)
