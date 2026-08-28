#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat <<'USAGE'
fm-board-report.sh - read-only board-vs-fleet divergence report.

Prints nothing and exits 0 when config/youtrack-token is absent or symlinked:
a home without a tracker sees zero output from this script. When configured,
it runs fm-youtrack.sh queries once and reports, per configured query, how
many matching issues are In Progress and how many are waiting on the
captain, followed by a DIVERGENCE section covering both directions: a local
backlog item with no issue reference, and a board issue that is In Progress
with no matching local task. Makes no write calls to the tracker.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

TOKEN_FILE="$CONFIG/youtrack-token"
[ -f "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ] || exit 0

QUERIES=$("$SCRIPT_DIR/fm-youtrack.sh" queries 2>/dev/null) || QUERIES=
if [ -z "$QUERIES" ]; then
  echo "BOARD: tracker is configured but no query returned any issue (check config/youtrack-queries)"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "BOARD: jq not found, cannot read tracker queries"; exit 0; }

per_query_counts() {
  printf '%s\n' "$QUERIES" | awk -F'\t' '
    { state=tolower($3) }
    state ~ /progress/ { inprog++ }
    state ~ /captain|waiting|review/ { waiting++ }
    END {
      printf "in progress: %d, waiting on captain: %d\n", inprog+0, waiting+0
    }
  '
}

echo "BOARD: $(per_query_counts)"
printf '%s\n' "$QUERIES" | awk -F'\t' 'tolower($3) ~ /progress/ { printf "BOARD in progress: %s (%s) %s\n", $1, $4, $5 }'
printf '%s\n' "$QUERIES" | awk -F'\t' 'tolower($3) ~ /captain|waiting|review/ { printf "BOARD waiting on captain: %s (%s) %s\n", $1, $4, $5 }'

BACKLOG="$DATA/backlog.md"
if [ -f "$BACKLOG" ] && [ ! -L "$BACKLOG" ]; then
  awk '
    /^##[[:space:]]+/ {
      heading=$0
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      inactive = (heading == "Done")
      next
    }
    !inactive && /^[-*][[:space:]]+/ && $0 !~ /\(issue:[[:space:]]*[^)]+\)/ {
      print "BOARD DIVERGENCE: local backlog item has no issue reference: " $0
    }
  ' "$BACKLOG"
fi

KNOWN_ISSUES=$(
  { [ -f "$BACKLOG" ] && [ ! -L "$BACKLOG" ] && grep -oE '\(issue:[[:space:]]*[^)]+\)' "$BACKLOG" | sed -E 's/\(issue:[[:space:]]*//; s/\)$//'; } 2>/dev/null
  { [ -d "$STATE" ] && grep -h -oE '^issue=.+' "$STATE"/*.meta 2>/dev/null | sed 's/^issue=//'; } 2>/dev/null
)

printf '%s\n' "$QUERIES" | awk -F'\t' 'tolower($3) ~ /progress/ { print $1 }' | while IFS= read -r issue_id; do
  [ -n "$issue_id" ] || continue
  case "$KNOWN_ISSUES" in
    *"$issue_id"*) ;;
    *) echo "BOARD DIVERGENCE: $issue_id is In Progress on the board with no matching local task" ;;
  esac
done

exit 0
