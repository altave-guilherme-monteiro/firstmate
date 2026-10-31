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

## No services on this machine

This machine is a laptop that also runs the supervisor and its other workers.
Do not run Docker (`docker compose`, `docker run`, `docker build`) on it.
Do not start a dev server, a local database, a broker, or a browser test harness on it.
Run services only on a remote host over ssh.
Verify with unit tests that need no running service, or on the remote target that your task names.
If the verification needs a running stack and no remote target is available, append `blocked: needs a remote host to run on` to your status file and stop.

## PR review loop

If your task opens a PR, request the automated review after the PR exists: post exactly `/review` as a PR comment with `gh-axi pr comment <number> --body '/review'`.
The reviewer does not start by itself, so a PR without that comment is not reviewed.
Read each finding that the review returns.
For each finding in the scope of your task, push a fix commit to the same branch.
Post `/review` again only after you push fixes, and stop when the review returns no finding in scope.
A finding is out of scope when its fix expands the task, changes behavior that nobody asked for, or needs a decision that is not yours. Escalate those findings and do not fix them.
Do not review your own work, do not argue with a reviewer, and do not resolve the review thread of another person.
