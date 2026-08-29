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
fm-retrospective.sh - a recurring look at delivery over a trailing window.

Reports, over a window (default the last 14 days), what this home ALREADY
has durable records for. It collects nothing new and runs no daemon: every
number comes from data/backlog.md, data/done-archive.md, gh-axi, quota-axi,
and bin/fm-board-report.sh, each read once. Any input that is missing or
unconfigured is skipped with one plain line, never estimated.

Usage:
  fm-retrospective.sh [--days N] [--since YYYY-MM-DD] [--repo OWNER/NAME]
  fm-retrospective.sh -h|--help

Options:
  --days N            window length in days, ending today (default 14).
  --since YYYY-MM-DD   window start date; overrides --days.
  --repo OWNER/NAME    repo to query PR activity for via gh-axi. Defaults to
                        this checkout's own origin remote when it points at
                        github.com; otherwise the PR section is skipped.

Sections, in order: delivered work by kind, delivery lead time (for items
that carry a recorded start date), PRs opened/merged (gh-axi), board issues
moved (bin/fm-youtrack.sh, only when config/youtrack-token is configured),
token and quota snapshot (quota-axi), the board-divergence trend (from
bin/fm-board-report.sh, tracked across runs of this script in
state/retrospective-board-trend.tsv), and a closing Limits section naming
what this report cannot measure. No quality score, no LLM judge, no numeric
external-benchmark comparison - external comparison is left to a human
reading this report, not computed here.

Exit status is always 0; a missing or failing input is reported inline and
never turns into a nonzero exit.
USAGE
}

DAYS=14
SINCE=""
REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --days) DAYS=${2:?--days needs a value}; shift 2 ;;
    --since) SINCE=${2:?--since needs a value}; shift 2 ;;
    --repo) REPO=${2:?--repo needs a value}; shift 2 ;;
    *) echo "fm-retrospective.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

TODAY_EPOCH=$(date +%s)
TODAY=$(date -u +%Y-%m-%d)
if [ -n "$SINCE" ]; then
  SINCE_EPOCH=$(TZ=UTC date -d "$SINCE" +%s 2>/dev/null) || {
    echo "fm-retrospective.sh: --since is not a valid date: $SINCE" >&2
    exit 2
  }
else
  SINCE_EPOCH=$((TODAY_EPOCH - DAYS * 86400))
  SINCE=$(date -u -d "@$SINCE_EPOCH" +%Y-%m-%d)
fi

date_to_epoch() { TZ=UTC date -d "$1" +%s 2>/dev/null; }
in_window() {
  local e
  e=$(date_to_epoch "$1") || return 1
  [ -n "$e" ] && [ "$e" -ge "$SINCE_EPOCH" ] && [ "$e" -le "$TODAY_EPOCH" ]
}

echo "# Delivery retrospective: $SINCE to $TODAY"
echo

echo "## Delivered work"
BACKLOG="$DATA/backlog.md"
ARCHIVE="$DATA/done-archive.md"
DONE_LINES=$(mktemp)
DONE_IN_WINDOW=$(mktemp)
LEAD_DAYS=$(mktemp)
IN_RANGE=$(mktemp)
trap 'rm -f "$DONE_LINES" "$DONE_IN_WINDOW" "$LEAD_DAYS" "$IN_RANGE"' EXIT

extract_done_lines() {
  local file=$1 in_done=${2:-0}
  [ -f "$file" ] || return 0
  awk -v want_done_section="$in_done" '
    want_done_section && /^##[[:space:]]+/ {
      heading=$0; sub(/^##[[:space:]]+/, "", heading); sub(/[[:space:]]+$/, "", heading)
      active = (heading == "Done")
      next
    }
    !want_done_section || active { if (/^- \[x\]/) print }
  ' "$file"
}

extract_done_lines "$BACKLOG" 1 >> "$DONE_LINES"
extract_done_lines "$ARCHIVE" 0 >> "$DONE_LINES"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  d=$(printf '%s\n' "$line" | grep -oE '\((done|merged|reported) [0-9]{4}-[0-9]{2}-[0-9]{2}\)' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
  [ -n "$d" ] || continue
  in_window "$d" || continue
  printf '%s\t%s\n' "$d" "$line" >> "$DONE_IN_WINDOW"
done < "$DONE_LINES"

TOTAL_DONE=$(wc -l < "$DONE_IN_WINDOW" | tr -d ' ')
if [ "$TOTAL_DONE" -eq 0 ]; then
  echo "No item carries a done/merged/reported date inside $SINCE..$TODAY."
else
  echo "$TOTAL_DONE item(s) completed in the window, by kind:"
  while IFS= read -r line; do
    k=$(printf '%s\n' "$line" | grep -oE '\(kind: [a-z-]+\)' | head -1 | sed -E 's/\(kind: //; s/\)//')
    printf '%s\n' "${k:-unlabeled}"
  done < <(cut -f2- "$DONE_IN_WINDOW") | sort | uniq -c | sort -rn | awk '{cnt=$1; $1=""; sub(/^ /,""); printf "  - %s: %d\n", $0, cnt}'
fi
echo

echo "## Delivery lead time"
UNDATED=0
while IFS=$'\t' read -r done_date line; do
  since=$(printf '%s\n' "$line" | grep -oE '\(since [0-9]{4}-[0-9]{2}-[0-9]{2}\)' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
  if [ -z "$since" ]; then
    UNDATED=$((UNDATED + 1))
    continue
  fi
  se=$(date_to_epoch "$since") || continue
  de=$(date_to_epoch "$done_date") || continue
  echo $(( (de - se) / 86400 )) >> "$LEAD_DAYS"
done < "$DONE_IN_WINDOW"

DATED=$(wc -l < "$LEAD_DAYS" | tr -d ' ')
if [ "$DATED" -eq 0 ]; then
  echo "No completed item in the window carries a recorded (since DATE) start - lead time not computable from current records."
else
  AVG=$(LC_ALL=C awk '{s+=$1; n++} END{printf "%.1f", s/n}' "$LEAD_DAYS")
  MED=$(LC_ALL=C sort -n "$LEAD_DAYS" | LC_ALL=C awk '{a[NR]=$1} END{if(NR%2==1) print a[(NR+1)/2]; else printf "%.1f", (a[NR/2]+a[NR/2+1])/2}')
  echo "$DATED item(s) with a recorded start date: average ${AVG}d, median ${MED}d."
  [ "$UNDATED" -eq 0 ] || echo "$UNDATED completed item(s) in the window have no recorded start date and are excluded from this figure."
fi
echo

echo "## Pull requests (gh-axi)"
if [ -z "$REPO" ]; then
  origin=$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null || true)
  case "$origin" in
    *github.com*)
      REPO=$(printf '%s\n' "$origin" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
      ;;
  esac
fi
if [ -z "$REPO" ]; then
  echo "No repo resolved (not a github.com origin and --repo not given) - PR activity skipped."
elif ! command -v gh-axi >/dev/null 2>&1; then
  echo "gh-axi not found on PATH - PR activity skipped."
else
  opened=$(gh-axi search prs "is:pr created:>=$SINCE" --repo "$REPO" --limit 1000 2>/dev/null | grep -oE '^count: [0-9]+' | grep -oE '[0-9]+')
  merged=$(gh-axi search prs "is:pr merged:>=$SINCE" --repo "$REPO" --limit 1000 2>/dev/null | grep -oE '^count: [0-9]+' | grep -oE '[0-9]+')
  if [ -z "$opened" ] || [ -z "$merged" ]; then
    echo "gh-axi search failed for $REPO - PR activity unavailable, not estimated."
  else
    echo "$REPO: $opened opened, $merged merged since $SINCE."
  fi
  echo "Scoped to $REPO only - other repos this fleet ships into are not queried unless named with --repo."
fi
echo

echo "## Board activity (YouTrack)"
TOKEN_FILE="$CONFIG/youtrack-token"
if [ ! -f "$TOKEN_FILE" ] || [ -L "$TOKEN_FILE" ]; then
  echo "Tracker not configured (config/youtrack-token absent) - board activity skipped."
else
  QUERY="updated: ${SINCE} .. ${TODAY}"
  ENC=$(printf '%s' "$QUERY" | sed 's/ /%20/g; s/:/%3A/g')
  RESP=$("$SCRIPT_DIR/fm-youtrack.sh" get "/api/issues?query=$ENC&fields=idReadable" 2>/dev/null)
  if [ -z "$RESP" ]; then
    echo "Could not read the tracker for this window - board activity unavailable, not estimated."
  elif command -v jq >/dev/null 2>&1 && printf '%s' "$RESP" | jq -e . >/dev/null 2>&1; then
    N=$(printf '%s' "$RESP" | jq 'length' 2>/dev/null)
    echo "${N:-0} issue(s) updated on the board since $SINCE."
  else
    echo "Tracker response was not usable JSON - board activity unavailable, not estimated."
  fi
fi
echo

echo "## Token and quota snapshot (quota-axi)"
if ! command -v quota-axi >/dev/null 2>&1; then
  echo "quota-axi not found on PATH - token and quota consumption is unavailable, not estimated."
else
  QJSON=$(quota-axi --json 2>/dev/null)
  if [ -z "$QJSON" ] || ! command -v jq >/dev/null 2>&1 || ! printf '%s' "$QJSON" | jq -e . >/dev/null 2>&1; then
    echo "quota-axi produced no readable output - token and quota consumption is unavailable, not estimated."
  else
    echo "Current per-provider quota state (a live snapshot, not a window-integrated total - quota-axi does not report historical usage):"
    printf '%s' "$QJSON" | jq -r '
      .providers[]? |
      .provider as $p |
      (.windows[]? | select(.kind=="weekly" or .kind=="session")) |
      "  - \($p) \(.label // .id): \(.percentRemaining)% remaining, pace \(.pace.status // "unknown")"
    ' 2>/dev/null || echo "  (could not parse provider windows)"
  fi
fi
echo

echo "## Board divergence trend"
TREND_FILE="$STATE/retrospective-board-trend.tsv"
if [ ! -f "$TOKEN_FILE" ] || [ -L "$TOKEN_FILE" ]; then
  echo "Tracker not configured - no divergence trend to track."
else
  REPORT=$("$SCRIPT_DIR/fm-board-report.sh" 2>/dev/null)
  A=$(printf '%s\n' "$REPORT" | grep -c '^BOARD DIVERGENCE: local backlog item has no issue reference:')
  B=$(printf '%s\n' "$REPORT" | grep -c '^BOARD DIVERGENCE:.*is In Progress on the board with no matching local task')
  mkdir -p "$STATE"
  printf '%s\t%s\t%s\n' "$TODAY" "$A" "$B" >> "$TREND_FILE"
  while IFS=$'\t' read -r d a b; do
    in_window "$d" && printf '%s\t%s\t%s\n' "$d" "$a" "$b" >> "$IN_RANGE"
  done < "$TREND_FILE"
  N=$(wc -l < "$IN_RANGE" | tr -d ' ')
  echo "Today: $A local backlog item(s) with no board issue, $B board issue(s) with no local task."
  if [ "$N" -lt 2 ]; then
    echo "Fewer than two recorded runs inside the window - no trend yet, this becomes meaningful as the script runs on a recurring cadence."
  else
    FIRST=$(head -1 "$IN_RANGE")
    IFS=$'\t' read -r fd fa fb <<<"$FIRST"
    trend_word() {
      local from=$1 to=$2
      if [ "$to" -gt "$from" ]; then echo "growing"
      elif [ "$to" -lt "$from" ]; then echo "shrinking"
      else echo "flat"; fi
    }
    echo "Since $fd ($fa/$fb): no-issue-reference is $(trend_word "$fa" "$A"), in-progress-with-no-local-task is $(trend_word "$fb" "$B")."
  fi
fi
echo

echo "## Limits"
cat <<'LIMITS'
- No quality score and no LLM judge: this report counts and times work, it
  never rates it.
- No numeric comparison against external benchmarks or other teams - that
  reading is left to the human looking at these numbers, not computed here.
- Lead time only covers items that carry a recorded (since DATE) start; a
  completed item with no such marker (common once it reaches data/done-archive.md)
  is counted as delivered but excluded from the lead-time figure.
- PR activity covers exactly one repo per run (the resolved origin, or
  --repo); work delivered into other repos this fleet ships into is not
  counted here.
- The quota-axi snapshot is a point-in-time read at the moment this report
  ran, not an integral of tokens spent across the window - it cannot say
  how much was spent inside SINCE..TODAY specifically, only where quota
  stands right now.
- The board-divergence trend is only as long as this script's own run
  history in state/retrospective-board-trend.tsv; a home running it for the
  first time has no trend yet.
- Kind counts trust the free-text (kind: ...) field recorded at intake;
  a task filed with the wrong kind, or none, is counted under whatever it
  was actually labeled.
LIMITS
