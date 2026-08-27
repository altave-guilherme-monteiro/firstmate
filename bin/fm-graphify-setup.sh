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
PreToolUse hook. The hook always exits 0 (it blocks only via its own JSON
permissionDecision payload, never via exit code) and writes only inside this
worktree's .claude/, never the primary checkout.

The strict hook is registered by writing .claude/settings.json, which a
Claude Code session reads at startup, so it does not retroactively hook the
session that ran this script. Treat the redirect as a benefit for any later
session in the same worktree, and treat the declared query verbs in the brief
as the mechanism the current crewmate actually uses.

Worktree hygiene: the artifacts this leaves behind must never reach a
crewmate's PR. graphify-out/ and graphify's .claude/settings.json.graphify-bak
are added to the checkout's local
.git/info/exclude (so this holds in any repo, not just one whose tracked
.gitignore happens to list them); CLAUDE.md, which graphify appends
its "## graphify" section to, is restored byte-for-byte after the install so
fm-ensure-agents-md.sh's canonical pointer form survives; and the modified
tracked .claude/settings.json, which must keep the hook registration to be
useful, is marked skip-worktree so `git add -A` and `git commit -a` do not
pick it up. Undo that mark with
`git update-index --no-skip-worktree .claude/settings.json` if a task ever
needs to commit a real settings.json change.
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

if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  EXCLUDE_FILE=$(git -C "$DIR" rev-parse --git-path info/exclude)
  case "$EXCLUDE_FILE" in
    /*) ;;
    *) EXCLUDE_FILE="$DIR/$EXCLUDE_FILE" ;;
  esac
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  for PATTERN in 'graphify-out/' '.claude/settings.json.graphify-bak'; do
    grep -qxF "$PATTERN" "$EXCLUDE_FILE" 2>/dev/null || printf '%s\n' "$PATTERN" >>"$EXCLUDE_FILE"
  done
fi

START=$(date +%s)
( cd "$DIR" && graphify update . --no-cluster )
END=$(date +%s)
echo "graphify graph built in $((END - START))s at $DIR/graphify-out/graph.json"

CLAUDE_MD_BACKUP=""
if [ -f "$DIR/CLAUDE.md" ]; then
  CLAUDE_MD_BACKUP=$(mktemp)
  cp "$DIR/CLAUDE.md" "$CLAUDE_MD_BACKUP"
fi

( cd "$DIR" && graphify claude install --strict )

if [ -n "$CLAUDE_MD_BACKUP" ]; then
  cp "$CLAUDE_MD_BACKUP" "$DIR/CLAUDE.md"
  rm -f "$CLAUDE_MD_BACKUP"
fi

if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
   git -C "$DIR" ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1; then
  git -C "$DIR" update-index --skip-worktree .claude/settings.json
fi

echo "graphify strict hook installed for $DIR (takes effect for the next Claude Code session in this worktree)"
