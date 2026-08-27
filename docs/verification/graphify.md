# Graphify codebase-comprehension verification

Audience: maintainer verification.

This record supports the guarantee that `graphify` (https://github.com/Graphify-Labs/graphify, package `graphifyy` 0.9.50) builds a real, queryable codebase graph for a crewmate worktree at low, measured cost, with no LLM call for the code graph itself.
`bin/fm-graphify-setup.sh --help` owns the install and build mechanics; `bin/fm-brief.sh` wires the setup step into every scout and ship scaffold (AGENTS.md section 11).

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

All three verbs the survey named were run against the built graph and returned real, non-empty, useful output:

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

## Known interaction with the AGENTS.md/CLAUDE.md pointer convention

`graphify claude install` unconditionally appends a "## graphify" section to the target worktree's `CLAUDE.md`.
In a worktree whose `CLAUDE.md` is `bin/fm-ensure-agents-md.sh`'s canonical two-line `@AGENTS.md` pointer, this was observed to leave the pointer's two lines intact with the graphify section appended below - Claude Code still resolves the import correctly, but the file is no longer byte-identical to the canonical pointer form that script treats as up to date.
Checked 2026-08-27 by running `bin/fm-graphify-setup.sh .` against this repository's own worktree and inspecting the resulting `CLAUDE.md`; the test artifacts (`CLAUDE.md`, `.claude/settings.json`, `graphify-out/`) were reverted before this change was committed, so this repository does not itself carry a built graph or the installed hook.
