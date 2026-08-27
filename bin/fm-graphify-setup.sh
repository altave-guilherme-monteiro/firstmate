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
graphify-out/.gitignore, written before the build starts so an interrupted or
failed build leaves nothing un-ignored; that file's catch-all `*` covers the
whole directory including any pre-existing graphify-out/.gitignore. Coverage is checked with
`git check-ignore`, not file existence, so a repo that already ships a partial
.gitignore gets the missing entries appended rather than silently skipped. Every
artifact family is probed, not just graph.json, so ignore rules that happen to
cover the graph but not graphify's cache/ or .rebuild.lock still get the
catch-all. A tracked ignore file is never edited: the build errors out instead,
and the hook install is skipped, so no change of the crewmate's is ever touched.
CLAUDE.md, which graphify appends its "## graphify" section to, is restored
byte-for-byte on every exit path - normal, failing, and an interrupting
INT/TERM/HUP - and deleted if graphify created it in a repo that had none, so
fm-ensure-agents-md.sh's canonical pointer form survives.

The strict Claude Code hook is installed only when .claude/settings.json does
not exist yet, so the file left behind is entirely graphify's and no content
of the crewmate's can be hidden by ignoring it. In that case a self-ignoring
.claude/.gitignore covering settings.json and settings.json.graphify-bak is
ensured before the install - a .claude/.gitignore this script did not create
keeps its own visibility, only the missing entries are appended, and only
settings.json coverage is required to proceed - and the script says so on
stdout: a task that
genuinely must commit .claude/settings.json can still do it with
`git add -f .claude/settings.json`. When the file already exists, tracked or
not, the install is skipped entirely - nothing is written, nothing is
restored, nothing is ignored, so a crewmate editing settings.json always sees
its own change in `git status`. The hook cannot help the session that ran
this script anyway (see above), so that skip costs nothing; run
`graphify claude install --strict` by hand if a session wants it and the
resulting diff is acceptable.
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
    PIPX_STATUS=0
    pipx install graphifyy || PIPX_STATUS=$?
    if ! command -v graphify >/dev/null 2>&1; then
      if [ "$PIPX_STATUS" -ne 0 ]; then
        echo "error: 'pipx install graphifyy' failed with status $PIPX_STATUS (see its output above) and graphify is still not available; install it manually (see https://github.com/Graphify-Labs/graphify)" >&2
      else
        echo "error: graphify is installed but not on PATH; ensure pipx's bin dir (usually ~/.local/bin) is on PATH, e.g. run 'pipx ensurepath' and start a new shell" >&2
      fi
      exit 1
    fi
  else
    echo "error: graphify not found and pipx is not installed; install pipx or graphify manually (see https://github.com/Graphify-Labs/graphify)" >&2
    exit 1
  fi
fi

ensure_self_ignoring() {
  IGNORE_FILE=$1
  shift
  IGNORE_DIR=$(dirname "$IGNORE_FILE")
  IGNORE_FILE_IS_OURS=false
  [ -e "$IGNORE_FILE" ] || IGNORE_FILE_IS_OURS=true
  for SPEC in "$@"; do
    SPEC_IS_REQUIRED=true
    case "$SPEC" in
      +*) SPEC_IS_REQUIRED=false; SPEC=${SPEC#+} ;;
    esac
    PROBE=${SPEC%%=*}
    PATTERN=${SPEC#*=}
    git -C "$DIR" check-ignore -q "$IGNORE_DIR/$PROBE" && continue
    if git -C "$DIR" ls-files --error-unmatch "$IGNORE_FILE" >/dev/null 2>&1; then
      [ "$SPEC_IS_REQUIRED" = true ] && return 1
      continue
    fi
    mkdir -p "$IGNORE_DIR"
    printf '%s\n' "$PATTERN" >>"$IGNORE_FILE"
  done
  if [ "$IGNORE_FILE_IS_OURS" = true ] && [ -e "$IGNORE_FILE" ] && ! git -C "$DIR" check-ignore -q "$IGNORE_FILE"; then
    printf '%s\n' '.gitignore' >>"$IGNORE_FILE"
  fi
  return 0
}

IN_GIT_WORKTREE=false
git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IN_GIT_WORKTREE=true

if [ "$IN_GIT_WORKTREE" = true ]; then
  ensure_self_ignoring "$DIR/graphify-out/.gitignore" 'graph.json=*' '.rebuild.lock=*' 'cache/entry=*' || {
    echo "error: graphify-out/ is not git-ignored and graphify-out/.gitignore is tracked in $DIR; ignore graphify-out/ yourself before building so the graph never reaches a PR" >&2
    exit 1
  }
fi

START=$(date +%s)
( cd "$DIR" && graphify update . --no-cluster )
END=$(date +%s)
echo "graphify graph built in $((END - START))s at $DIR/graphify-out/graph.json"

if [ -e "$DIR/.claude/settings.json" ]; then
  echo "graphify strict hook skipped for $DIR: .claude/settings.json already exists and is left untouched so no edit of yours is hidden from git; run 'graphify claude install --strict' yourself if you want the hook"
  exit 0
fi

if [ "$IN_GIT_WORKTREE" = true ]; then
  ensure_self_ignoring "$DIR/.claude/.gitignore" 'settings.json=settings.json' '+settings.json.graphify-bak=settings.json.graphify-bak' || {
    echo "graphify strict hook skipped for $DIR: .claude/settings.json is not git-ignored and .claude/.gitignore is tracked, so installing the hook would leave a committable artifact; ignore it yourself or run 'graphify claude install --strict' by hand"
    exit 0
  }
fi

CLAUDE_MD_BACKUP=""
CLAUDE_MD_CAPTURED=false
CLAUDE_MD_RESTORED=false
restore_claude_md() {
  [ "$CLAUDE_MD_RESTORED" = true ] && return 0
  [ "$CLAUDE_MD_CAPTURED" = true ] || return 0
  CLAUDE_MD_RESTORED=true
  if [ -n "$CLAUDE_MD_BACKUP" ]; then
    cp "$CLAUDE_MD_BACKUP" "$DIR/CLAUDE.md"
    rm -f "$CLAUDE_MD_BACKUP"
  else
    rm -f "$DIR/CLAUDE.md"
  fi
  return 0
}
restore_claude_md_and_die() {
  restore_claude_md
  exit 130
}
trap restore_claude_md EXIT
trap restore_claude_md_and_die INT TERM HUP

if [ -f "$DIR/CLAUDE.md" ]; then
  CLAUDE_MD_BACKUP=$(mktemp)
  cp "$DIR/CLAUDE.md" "$CLAUDE_MD_BACKUP"
fi
CLAUDE_MD_CAPTURED=true

( cd "$DIR" && graphify claude install --strict )

echo "graphify strict hook installed for $DIR (takes effect for the next Claude Code session in this worktree)"
if [ "$IN_GIT_WORKTREE" = true ]; then
  echo "note: .claude/settings.json is git-ignored in this worktree; use 'git add -f .claude/settings.json' if your task must commit it"
fi
