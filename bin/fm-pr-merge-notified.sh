#!/usr/bin/env bash
# fm-pr-merge-notified.sh - answer whether this home has ALREADY published a
# merge outcome for the pull request or merge request a piece of text names.
#
# Reads the text on stdin, extracts every https:// forge URL candidate it
# contains, canonicalizes each one through bin/fm-pr-lib.sh's own parser, and
# compares that canonical identity against the merge-notification markers
# bin/fm-pr-lib.sh owns. bin/fm-merge-outcome-lib.sh commits one of those
# markers whenever a merge is published to this home's supervision destination,
# so a matching marker is proof the merge already reached that destination.
#
# The question is home-wide rather than task-scoped: a home has exactly one
# supervision destination, so any task's marker carrying that exact canonical
# identity answers it. A different pull request, a URL this home never watched,
# and text naming no pull request at all are all "not yet published".
#
# Exit status:
#   0  the text names a merge this home already published
#   1  it does not, including unreadable state, no marker, and no URL
#   2  usage error
#
# Reads only; nothing here mutates state. Callers must treat any non-zero exit
# as "not yet published" and deliver the outcome, so an unreadable state
# directory costs a duplicate report rather than a lost one.
#
# Usage: fm-pr-merge-notified.sh   (text on stdin)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 0 ]; then
  echo "usage: fm-pr-merge-notified.sh   (text on stdin)" >&2
  exit 2
fi

[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1

# Bounded read: the caller's text is one or two sentences of outcome language,
# never a stream.
TEXT=$(head -c 65536 || true)
[ -n "$TEXT" ] || exit 1

# A canonical pull request or merge request URL always ends in its number, so
# trailing sentence punctuation is stripped by dropping every trailing
# non-digit. fm_pr_url_parse is the sole judge of what survives that.
url_candidates() {
  printf '%s\n' "$TEXT" \
    | grep -oE 'https://[-A-Za-z0-9._~:/?#@!$&()*+,;=%]+' \
    | sed 's/[^0-9]*$//' \
    | grep -v '^$' \
    || true
}

marker_matches() {  # <provider> <host> <path> <number>
  local provider=$1 host=$2 path=$3 number=$4 marker id
  for marker in "$STATE"/*.pr-poll-merge-notified; do
    [ -e "$marker" ] || continue
    id=$(basename "$marker" .pr-poll-merge-notified)
    fm_pr_task_id_valid "$id" || continue
    if fm_pr_poll_merge_already_notified "$STATE" "$id" \
        "$provider" "$host" "$path" "$number"; then
      return 0
    fi
  done
  return 1
}

while IFS= read -r candidate; do
  fm_pr_url_parse "$candidate" || continue
  if marker_matches "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
    exit 0
  fi
done <<CANDIDATES
$(url_candidates)
CANDIDATES

exit 1
