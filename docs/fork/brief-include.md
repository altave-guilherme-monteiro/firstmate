## Code graph

Build the code graph of this copy before you read files.
Run `<home>/bin/fm-graphify-setup.sh .`, where `<home>` is the folder that holds the `state/` folder of your status file.
If the build fails, record the failure and use grep.
No part of this task depends on the graph.
Use `graphify query "<question>"`, `graphify path A B`, and `graphify explain "<node>"` for structural questions.

## Security scan

Before you report the work as complete, run `semgrep --config=p/security-audit --config=p/secrets`.
Do not use `--autofix`.
The scan covers the full copy and has no baseline.
Examine only the WARNING and ERROR findings on the lines that you changed.
Ignore findings that your work did not cause.
Correct each applicable finding, or give the reason to keep it in your report.
If `semgrep` is not installed, record that and continue.

## Library documentation

Use the `context7` MCP tool (`resolve-library-id`, then `query-docs`) when you write code for a library, framework, SDK, or CLI.
Do not rely on memory for library behavior.
If `context7` is not available, record that and continue.

## No-mistakes rebase gate

The rebase gate can report unpushed main commits that are already on `origin/main`.
Before you respond to that gate, do these steps:

1. Run `git fetch origin`.
2. Compare `git rev-parse origin/main` with `git ls-remote no-mistakes main`.
3. A difference means that the gate compares an old internal mirror, not your copy, so the report is false.
4. If `git rev-list --count origin/main..HEAD` shows only your commits, respond with `no-mistakes axi respond --action skip`.

Do not respond with `--action approve` in this condition, because that action adds commits that are already merged to your PR.
Do not restart the shared no-mistakes daemon, because a restart stops the runs of other workers.
If the comparison does not give a clear result, escalate.
