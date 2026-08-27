#!/usr/bin/env bash
set -eu

usage() {
  cat <<'EOF'
usage: fm-graphify-setup.sh [worktree-dir]

Builds a local codebase-comprehension graph for a crewmate's worktree using
graphify (https://github.com/Graphify-Labs/graphify): local tree-sitter AST
parsing, no LLM call, nothing leaves the machine for the code graph itself.

Called on-demand by a crewmate as an early setup step (bin/fm-brief.sh wires
the instruction into the generated brief) rather than once per repo checkout
during worktree provisioning, so no fm-spawn.sh backend has to learn about it
and a task that never calls this script is unaffected. Measured cost on
firstmate's own ~437-file repo is a few seconds per run with no LLM cost; see
docs/verification/ for the dated measurement. If a future repo's build cost
stops being cheap enough to pay per-crewmate, move the `graphify update` call
below into worktree provisioning instead.

Idempotent: safe to re-run. Installs the pipx-managed `graphify` CLI if
missing, refreshes graphify-out/graph.json in the target directory with
`--no-cluster` (skips the slower community-detection pass this per-task use
does not need), and installs graphify's project-scoped Claude Code `--strict`
PreToolUse hook so the crewmate's first raw file read is redirected into a
graph query. The hook always exits 0 (it blocks only via its own JSON
permissionDecision payload, never via exit code) and writes only inside this
worktree's .claude/ and CLAUDE.md, never the primary checkout.

Known caveat: graphify appends its "## graphify" section into CLAUDE.md
unconditionally. In a worktree whose CLAUDE.md is fm-ensure-agents-md.sh's
canonical two-line @AGENTS.md pointer, this leaves extra content alongside
that pointer rather than breaking it - harmless for Claude Code to read, but
no longer the exact pointer form fm-ensure-agents-md.sh treats as canonical.
Do not run fm-ensure-agents-md.sh's promotion path expecting it to reconcile
this on its own; restoring the exact pointer, if ever needed, is a manual fix.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)

if ! command -v graphify >/dev/null 2>&1; then
  if command -v pipx >/dev/null 2>&1; then
    echo "graphify not found; installing with pipx..." >&2
    pipx install graphifyy
  else
    echo "error: graphify not found and pipx is not installed; install pipx or graphify manually (see https://github.com/Graphify-Labs/graphify)" >&2
    exit 1
  fi
fi

START=$(date +%s)
( cd "$DIR" && graphify update . --no-cluster )
END=$(date +%s)
echo "graphify graph built in $((END - START))s at $DIR/graphify-out/graph.json"

( cd "$DIR" && graphify claude install --strict )
echo "graphify strict hook installed for $DIR"
