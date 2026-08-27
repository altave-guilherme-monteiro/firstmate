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
crewmate's PR, and nothing here writes outside the target worktree (a linked
worktree shares .git/info/exclude with the primary checkout, so that file is
deliberately not touched). graphify-out/ is made self-ignoring with its own
graphify-out/.gitignore, which works in any repo whose tracked .gitignore
does not already list it. CLAUDE.md, which graphify appends its "## graphify"
section to, is restored byte-for-byte on every exit path including failure,
and deleted if graphify created it in a repo that had none, so
fm-ensure-agents-md.sh's canonical pointer form survives. graphify's
.claude/settings.json.graphify-bak, and .claude/settings.json itself when it
is untracked or newly created, are covered by a self-ignoring
.claude/.gitignore, written before the install runs so the coverage also
holds when the install itself fails (written only if that file does not
already exist).

When .claude/settings.json is tracked, its pre-install content is restored
on every exit path too, so the strict hook is only left installed where the
file is untracked or graphify created it. Nothing is ever hidden from git:
no index state is touched, a crewmate whose task is to edit settings.json
still sees its own change in `git status`, and a later rebase behaves
normally. The hook cannot help the session that ran this script anyway (see
above), so a tracked settings.json trades it for that safety; run
`graphify claude install --strict` by hand if a session in a disposable
worktree wants it and the resulting diff is acceptable.
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

ensure_self_ignoring() {
  IGNORE_FILE=$1
  shift
  [ -e "$IGNORE_FILE" ] && return 0
  mkdir -p "$(dirname "$IGNORE_FILE")"
  printf '%s\n' "$@" >"$IGNORE_FILE"
}

IN_GIT_WORKTREE=false
git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IN_GIT_WORKTREE=true

START=$(date +%s)
( cd "$DIR" && graphify update . --no-cluster )
END=$(date +%s)
echo "graphify graph built in $((END - START))s at $DIR/graphify-out/graph.json"

if [ "$IN_GIT_WORKTREE" = true ] && [ -d "$DIR/graphify-out" ]; then
  ensure_self_ignoring "$DIR/graphify-out/.gitignore" '*'
fi

snapshot_file() {
  SNAPSHOT_PATH=$1
  [ -f "$SNAPSHOT_PATH" ] || return 0
  SNAPSHOT_COPY=$(mktemp)
  cp "$SNAPSHOT_PATH" "$SNAPSHOT_COPY"
  printf '%s\n' "$SNAPSHOT_COPY"
}

restore_file() {
  TARGET=$1
  BACKUP=$2
  if [ -n "$BACKUP" ]; then
    cp "$BACKUP" "$TARGET"
    rm -f "$BACKUP"
  else
    rm -f "$TARGET"
  fi
  return 0
}

SETTINGS_TRACKED=false
if [ "$IN_GIT_WORKTREE" = true ] &&
   git -C "$DIR" ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1; then
  SETTINGS_TRACKED=true
fi

if [ "$IN_GIT_WORKTREE" = true ]; then
  if [ "$SETTINGS_TRACKED" = true ]; then
    ensure_self_ignoring "$DIR/.claude/.gitignore" '.gitignore' 'settings.json.graphify-bak'
  else
    ensure_self_ignoring "$DIR/.claude/.gitignore" '.gitignore' 'settings.json' 'settings.json.graphify-bak'
  fi
fi

CLAUDE_MD_BACKUP=$(snapshot_file "$DIR/CLAUDE.md")
SETTINGS_BACKUP=""
[ "$SETTINGS_TRACKED" = true ] && SETTINGS_BACKUP=$(snapshot_file "$DIR/.claude/settings.json")

restore_snapshots() {
  restore_file "$DIR/CLAUDE.md" "$CLAUDE_MD_BACKUP"
  [ "$SETTINGS_TRACKED" = true ] && restore_file "$DIR/.claude/settings.json" "$SETTINGS_BACKUP"
  return 0
}
trap restore_snapshots EXIT

( cd "$DIR" && graphify claude install --strict )

if [ "$SETTINGS_TRACKED" = true ]; then
  echo "graphify strict hook not retained for $DIR: .claude/settings.json is tracked and was restored so no crewmate edit to it is hidden from git"
else
  echo "graphify strict hook installed for $DIR (takes effect for the next Claude Code session in this worktree)"
fi
