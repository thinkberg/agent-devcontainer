# .devcontainer/rules — this project's harness rules

`rules.json` is the project overlay for the safety harness (the engine is
in `.devcontainer/harness/`, installed into the image at
`/usr/local/lib/harness`). Put project checkers into `checkers/` and
name them as `{project}/checkers/<name>` in a rule. This directory is
mounted read-only inside the container: the agent proposes changes to
these files as text, you apply them on the host.
