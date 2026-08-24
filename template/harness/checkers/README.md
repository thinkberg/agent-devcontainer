# checkers/ — the checker contract

A checker is a program. It gets its target as arguments, and the hook
input as JSON on stdin when a hook runs it. It prints findings, one per
line, to stdout. The exit code decides:

| Exit | Meaning |
|------|---------|
| 0 | pass |
| 1 | violation — the findings say what |
| 2 | approval needed — a human decision is missing |
| 3+ | error — the check could not run. The dispatchers treat this as a violation (fail closed) and say so |

Every checker is idempotent and read-only on the workspace (a build
check renders into a temp dir). A rule names its checker in `check.run`
with `{checkers}` (this directory) or `{project}` (the project overlay's
`checkers/`), plus `{root}`, `{file}`, `{repo}`. `harness check` runs
the rules with trigger `gate` on demand; the hooks run the rest at their
trigger. Checkers that need configuration read it from the merged
registry (`HARNESS_RULES`, exported by the dispatcher).
