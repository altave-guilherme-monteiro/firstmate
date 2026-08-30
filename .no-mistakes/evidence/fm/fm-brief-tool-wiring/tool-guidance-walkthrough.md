# fm-brief tool wiring - end-to-end evidence

Generated 2026-08-29 from bin/fm-brief.sh at 1af0fec.

## 1. What a ship worker (--mode no-mistakes) actually reads

```
# Setup
You are in a disposable git worktree of acme-api, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: `git rev-parse --git-dir` and `git rev-parse --git-common-dir` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append `blocked: launched in primary checkout, not an isolated worktree` to the status file and stop.

1. First action: create your branch: `git checkout -b fm/demo-ship`
2. Run `no-mistakes doctor`; if it reports the repo is not initialized here, run `no-mistakes init`.

Before you consider your implementation complete, run `semgrep --config=p/security-audit --config=p/secrets` (read-only, no `--autofix`); it scans the whole worktree against no baseline, so read the output yourself and weigh only the WARNING and ERROR findings that touch the files and lines you changed, using judgment to skip pre-existing findings your work did not introduce. Fix those or explicitly justify them wherever this task's result is written up; this is a suggestion, not an enforced gate. If `semgrep` is not installed, note it and move on - nothing in this task depends on it.
Live library and framework documentation is available through the `context7` MCP tool (`resolve-library-id` then `query-docs`); consult it instead of relying on memory whenever you write code against a library, framework, SDK, or CLI - this is expected practice, not an enforced gate. If the `context7` tool is not available, note it and fall back to your own knowledge - nothing in this task depends on it.

```

## 2. What a scout worker reads

```
# Setup
You are in a disposable git worktree of acme-api, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

Before you finish your work, run `semgrep --config=p/security-audit --config=p/secrets` (read-only, no `--autofix`); it scans the whole worktree against no baseline, so read the output yourself and weigh only the WARNING and ERROR findings that touch the files and lines you changed, using judgment to skip pre-existing findings your work did not introduce. Fix those or call them out in your report; this is a suggestion, not an enforced gate. If `semgrep` is not installed, note it and move on - nothing in this task depends on it.
Live library and framework documentation is available through the `context7` MCP tool (`resolve-library-id` then `query-docs`); consult it instead of relying on memory whenever you write code against a library, framework, SDK, or CLI - this is expected practice, not an enforced gate. If the `context7` tool is not available, note it and fall back to your own knowledge - nothing in this task depends on it.

```

## 3. local-only mode: guidance never names a PR that mode does not open

Setup section grep for "PR": 0 hits. Rules 1 in the same brief:

```
PR occurrences in Setup: 0
24:1. Never push to any remote and never open a PR. Work only on your `fm/demo-local` branch; firstmate handles the merge into local `main`.
```

## 4. Guidance is one shared string, identical in all three ship modes

```
$ cmp no-mistakes vs direct-PR vs local-only guidance blocks
IDENTICAL
```

## 5. The prescribed semgrep command, actually run against this repo

```
$ semgrep --config=p/security-audit --config=p/secrets --jobs 1
  yaml              1       5                                                                                           
                                                                                                                        
                
                
┌──────────────┐
│ Scan Summary │
└──────────────┘
✅ Scan completed successfully.
 • Findings: 0 (0 blocking)
 • Rules run: 147
 • Targets scanned: 287
 • Parsed lines: ~100.0%
 • Scan skipped: 
   ◦ Files larger than  files 1.0 MB: 1
   ◦ Files matching .semgrepignore patterns: 183
 • Scan was limited to files tracked by git
 • For a detailed list of skipped files and lines, run semgrep with the --verbose flag
Ran 147 rules on 287 files: 0 findings.
```

Note: the default parallel path fails in this sandbox with
`Unix_error: Cannot allocate memory io_uring_queue_init` (RLIMIT_MEMLOCK 8192);
`--jobs 1` completes normally. Environment limit, not a repo or change issue.

## 6. The prescribed context7 sequence, actually exercised

```
resolve-library-id("semgrep") -> /semgrep/semgrep-docs (High reputation, 5126 snippets)
query-docs("/semgrep/semgrep-docs", "multiple --config registry rulesets")
  -> "Combine multiple rulesets ... by using the --config flag multiple times"
  -> semgrep scan --config p/python --config PATH/TO/RULE.YAML
```

Both MCP calls succeeded; live docs confirm the multi---config form the brief prescribes is valid usage.
