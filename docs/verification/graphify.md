# Graphify codebase-comprehension verification

Audience: maintainer verification.

This record supports the guarantee that `graphify` (https://github.com/Graphify-Labs/graphify, package `graphifyy` 0.9.50) builds a real, queryable codebase graph for a crewmate worktree at low, measured cost, with no LLM call for the code graph itself.
`bin/fm-graphify-setup.sh --help` owns the install and build mechanics, the `codebase-graph` skill owns the situational procedure, and `bin/fm-brief.sh` wires the setup step into every scout and ship scaffold (AGENTS.md section 11).

## Install and version

Checked 2026-08-27 with `pipx install graphifyy`:

```text
installed package graphifyy 0.9.50, installed using Python 3.13.7
These apps are now globally available
  - graphify
  - graphify-mcp
```

`graphify --version` reported `graphify 0.9.50`.
`graphify install --project --strict` and `graphify claude install --strict` are both real, present flags in the installed package's `install.py` (grepped directly, not taken from the README).

## Graph build cost

Checked 2026-08-27 against this repository's own worktree (437-438 tracked files at the time), cold cache, `graphify update . --no-cluster`:

```text
Re-extracting code files in . (no LLM needed)...
  AST extraction: 100/438 uncached files (22%) [16 workers]
  AST extraction: 200/438 uncached files (45%) [16 workers]
  AST extraction: 300/438 uncached files (68%) [16 workers]
  AST extraction: 400/438 uncached files (91%) [16 workers]
  AST extraction: 438/438 uncached files (100%) [16 workers]
[graphify watch] Rebuilt (no clustering): 7857 nodes, 21602 edges
[graphify watch] graph.json updated in graphify-out
```

Wall time measured with `time`: `real 0m3.656s` (`user 0m9.406s`, `sys 0m1.389s`, 16-way parallel AST extraction).
No `GEMINI_API_KEY`/`GOOGLE_API_KEY`/etc. was set, confirming the code graph itself made no LLM call.
A few seconds per crewmate spawn is judged cheap enough to run on demand rather than once per repo checkout during worktree provisioning; see `bin/fm-graphify-setup.sh --help` for the upgrade path if a future repo's file count makes this no longer true.

## Query verbs

All three declared verbs (`query`, `path`, `explain`) were run against the built graph and returned real, non-empty, useful output:

```text
$ graphify query "fm-graphify-setup"
Graph: graphify-out/graph.json (7903 nodes) | Traversal: BFS depth=2 | Start: ['Setup', 'Graphify codebase-comprehension verification'] | 15 nodes found

NODE Graphify codebase-comprehension verification [src=docs/verification/graphify.md loc=L1 community=]
NODE Graph build cost [src=docs/verification/graphify.md loc=L22 community=]
NODE Query verbs [src=docs/verification/graphify.md loc=L41 community=]
...
EDGE graphify.md --contains [EXTRACTED]--> Graphify codebase-comprehension verification at=docs/verification/graphify.md:L1
```

`query` is the keyword entry point used when only a subject is known rather than a node name; it is a BFS over the built `graph.json` with no LLM call, and it reports its own traversal depth, start nodes and token budget.

```text
$ graphify explain "fm-spawn.sh"
Node: fm-spawn.sh
  ID:        bin_fm_spawn
  Source:    bin/fm-spawn.sh L1
  Type:      code
  Degree:    59
Connections (59):
  --> fm-wake-lib.sh [imports_from] [INFERRED] bin/fm-spawn.sh:L251
  --> fm-backend.sh [imports_from] [INFERRED] bin/fm-spawn.sh:L257
  ...

$ graphify affected "fm-spawn.sh"
Relations: calls, indirect_call, references, imports, imports_from, dynamic_import, re_exports, inherits, extends, implements, uses, mixes_in, embeds, requires
Depth: 2
No affected nodes found.

$ graphify path "fm-spawn.sh" "fm-brief.sh" --undirected
Shortest path (4 hops):
  fm-spawn.sh --imports_from [INFERRED]--> fm-backend.sh <--imports_from [INFERRED]-- fm-crew-state.sh --imports_from [INFERRED]--> fm-classify-lib.sh <--imports_from [INFERRED]-- fm-brief.sh
```

`explain` directly answers "what reaches this file" (`fm-spawn.sh`'s 59 real inbound/outbound edges, each tagged `EXTRACTED` or `INFERRED`) without a grep.
`path --undirected` found the real four-hop dependency chain between two unrelated-looking scripts that share no direct edge; the plain directed `graphify path` correctly reported no directed path exists, which is itself informative.
`affected` returned no results for `fm-spawn.sh` in this repository because nothing in the indexed graph calls into it by a tracked relation from another node in the reverse direction it traverses; this is a true negative, not a tool failure, confirmed by `explain` showing the file does have many outbound edges.

## Worktree hygiene

`graphify claude install` unconditionally appends a "## graphify" section to the target worktree's `CLAUDE.md`, writes `.claude/settings.json` plus a `.claude/settings.json.graphify-bak`, and `graphify update` writes `graphify-out/`.
None of that may reach a crewmate's PR, and none of the hygiene may reach the primary checkout: a linked worktree shares `.git/info/exclude` with the primary checkout (`git rev-parse --git-path info/exclude` resolves to the common git dir), so that file is deliberately not used.
Instead `bin/fm-graphify-setup.sh` writes a self-ignoring `graphify-out/.gitignore` containing `*` *before* the build starts (so an interrupted build leaves nothing un-ignored), restores `CLAUDE.md` on every exit path including failure - deleting it when graphify created it in a repo that had none - and runs `graphify claude install --strict` only when `.claude/settings.json` does not exist yet, where the resulting file is entirely graphify's and is covered by a self-ignoring `.claude/.gitignore`. Where that file already exists, tracked or not, the install is skipped, so nothing of a crewmate's own is ever hidden by an ignore rule or an index flag.
That trade - the hook is dropped rather than risking a crewmate's own `.claude/settings.json` work being invisible - is recorded in the `codebase-graph` skill, together with the `git add -f` escape for the ignored case.

Checked 2026-08-27 by running `bin/fm-graphify-setup.sh .` twice against this repository's own worktree:

```text
$ md5sum CLAUDE.md > /tmp/cmd5; bash bin/fm-graphify-setup.sh . >/dev/null; md5sum -c /tmp/cmd5
CLAUDE.md: OK
$ git status --short
 M .gitignore
 M AGENTS.md
 M bin/fm-graphify-setup.sh
 M docs/documentation-audiences.json
?? .agents/skills/codebase-graph/
```

Only this change's own edits remain; no graphify artifact appears.

Re-checked 2026-08-27 in three throwaway repos to cover the paths this repository does not exercise, all with `git status --short` empty afterwards:

```text
repo with no CLAUDE.md and no .claude/   -> exit 0; CLAUDE.md absent again; .claude/{settings.json,.gitignore} ignored
repo with tracked CLAUDE.md + settings.json -> exit 0; md5sum -c CLAUDE.md OK; install skipped, settings.json untouched, no index state touched
graphify stub that appends to CLAUDE.md then exits 3 -> exit 3 propagated; CLAUDE.md restored by the EXIT trap
```
`tests/fm-graphify-setup.test.sh` now covers these hygiene paths as a regression test, so they are re-checked on every run of `bin/fm-test-run.sh` rather than only by the dated manual runs above.

An incremental rerun after the first build cost `real 0m4.231s` on this repository, so a rebuild after edits stays in the same few-seconds band as the cold build.

## Strict hook timing

`graphify claude install --strict` registers its PreToolUse hooks by writing `.claude/settings.json`, which a Claude Code session reads at startup.
It therefore does not retroactively hook the session that ran the install, and the strict "first raw read is redirected into a graph query" behavior applies to the next session in that worktree.
The declared mechanism for the current crewmate is the explicit `query`/`path`/`explain` instruction in `bin/fm-brief.sh`'s generated brief, not the hook; the `codebase-graph` skill states this so no crewmate assumes an inert redirect is protecting it.
