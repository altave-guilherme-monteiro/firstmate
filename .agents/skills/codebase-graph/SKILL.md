---
name: codebase-graph
description: >-
  Answer structural questions about a checkout from a local graphify code graph instead of blind grepping.
  Load before briefing a crewmate that must trace structure, when running bin/fm-graphify-setup.sh, when a graphify query/path/explain call returns nothing or errors, or when a graph may be stale after edits.
metadata:
  internal: true
---

# codebase-graph

`bin/fm-graphify-setup.sh --help` owns the mechanics (install, build flags, artifact hygiene, cost).
This skill owns when to build and how to read the result.

## When to build

- Build once per crewmate worktree, as the early setup step the scout and ship briefs declare.
- Rebuild with the same command after the crewmate's own edits change file structure; `graphify update` is incremental and caches unchanged files, so a rebuild costs far less than the first build.
- Do not build for a task that never asks a structural question; the script is opt-in and nothing depends on it.

## Which verb answers which question

- `graphify query "<question>"` - keyword entry point; use it first when only the subject is known, not a node name. It is a BFS over the built graph, not an LLM call.
- `graphify explain "<node>"` - "what reaches this file" and "what does this file reach"; lists every inbound and outbound edge with its relation and `EXTRACTED` or `INFERRED` tag.
- `graphify path A B` - "how does A connect to B"; add `--undirected` when the directed run reports no path, since an undirected chain through a shared dependency is usually the real answer.

Every edge carries `EXTRACTED` (read from the AST) or `INFERRED` (heuristic). Treat `INFERRED` as a lead to confirm by reading the file, not as proof.

## When it does not answer

- Empty result from a correct-looking node name usually means the graph predates the current files: rebuild, then retry.
- Build failure or a missing `graphify` CLI is never a blocker. Say so in the report or status line and fall back to grep; no spawn, teardown, or task depends on the graph existing.
- The `--strict` Claude Code hook is registered in `.claude/settings.json` and read at session start, so it does not hook the session that installed it. The declared verbs above, not the hook, are the mechanism the current crewmate uses.
