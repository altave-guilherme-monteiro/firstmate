#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
fm-evidence.sh - post a Delivery Stage evidence record to a tracker issue.

Proof of a change belongs on the issue, not in a loose screenshot or file
under firstmate's own directory: this script is the one place that turns a
completed check into a durable, team-visible tracker comment. It follows
the Evidence Record contract in data/delivery-stage/DeliveryStage.md
section 4 (read that file first - it is the authority, this script only
implements it) and delegates every tracker call to bin/fm-youtrack.sh, which
owns authentication.

Usage:
  fm-evidence.sh <issue-id> <record-file> [--attach <path>]...
  fm-evidence.sh -h|--help

<issue-id>     a tracker issue id, e.g. FM-123.
<record-file>  a text file, one evidence entry per line, pipe-separated:
                 VAL_ID|REQ_ID|method|where|outcome|observer
               method is "executed" or "observed". observer is required
               (non-blank) when method is "observed" and ignored otherwise.
               A blank line, or a line whose first character is a leading
               hash mark, is skipped.
--attach <path>  a screenshot or artifact file to upload to the issue and
               reference from the comment; repeatable. The file is never
               left as a bare path in the comment text.

Behavior:
  Every --attach is uploaded to the issue's attachment endpoint through
  "fm-youtrack.sh attach" BEFORE the comment is posted. If the tracker
  rejects any attachment, this script stops immediately, prints the
  tracker's exact rejection, and posts NOTHING - a partially-evidenced
  comment is worse than no comment, and silently dropping the attachment is
  the failure this script exists to prevent.

  On success, the record entries and a link to each uploaded attachment are
  rendered into one Markdown comment and posted via
  "fm-youtrack.sh post /api/issues/<id>/comments". The raw comment
  response is printed on success.

  Refuses cleanly, with no network call, when the tracker is not
  configured (no config/youtrack-token) - exactly as fm-youtrack.sh does,
  since this script performs no authentication of its own and always
  routes through it.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 2
fi

ISSUE_ID=$1
RECORD_FILE=$2
shift 2

ATTACH_PATHS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attach)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "fm-evidence: --attach needs a path" >&2; exit 2; }
      ATTACH_PATHS+=("$2")
      shift 2
      ;;
    *)
      echo "fm-evidence: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$ISSUE_ID" ] || { usage >&2; exit 2; }
[ -f "$RECORD_FILE" ] || { echo "fm-evidence: record file not found: $RECORD_FILE" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "fm-evidence: jq not found" >&2; exit 1; }

YT="$SCRIPT_DIR/fm-youtrack.sh"

for f in "${ATTACH_PATHS[@]:-}"; do
  [ -z "$f" ] || [ -f "$f" ] || { echo "fm-evidence: attachment file not found: $f" >&2; exit 1; }
done

MARK='#'
BODY="## Evidence Record"$'\n\n'
any_entry=0
while IFS='|' read -r val_id req_id method where outcome observer || [ -n "$val_id" ]; do
  case "$val_id" in
    '') continue ;;
    "$MARK"*) continue ;;
  esac
  case "$method" in
    executed) how="executed automatically" ;;
    observed)
      [ -n "$observer" ] || {
        echo "fm-evidence: $val_id is observed but names no observer" >&2
        exit 2
      }
      how="observed manually by $observer"
      ;;
    *)
      echo "fm-evidence: $val_id has an unknown method '$method' (want executed|observed)" >&2
      exit 2
      ;;
  esac
  any_entry=1
  BODY+="- **${val_id}** (traces to ${req_id}): ${outcome} - ${how} at ${where}"$'\n'
done < "$RECORD_FILE"

[ "$any_entry" -eq 1 ] || { echo "fm-evidence: record file has no usable entries" >&2; exit 1; }

if [ "${#ATTACH_PATHS[@]}" -gt 0 ]; then
  BODY+=$'\n'"**Attachments:**"$'\n'
  BASE_URL=$("$YT" url) || { echo "fm-evidence: tracker not configured" >&2; exit 1; }
  for f in "${ATTACH_PATHS[@]}"; do
    resp=$("$YT" attach "/api/issues/${ISSUE_ID}/attachments?fields=id,name,url" "$f") || {
      echo "fm-evidence: tracker rejected attachment $f - nothing was posted" >&2
      exit 1
    }
    name=$(printf '%s' "$resp" | jq -r '(if type == "array" then .[0] else . end).name // empty')
    url=$(printf '%s' "$resp" | jq -r '(if type == "array" then .[0] else . end).url // empty')
    [ -n "$name" ] && [ -n "$url" ] || {
      echo "fm-evidence: tracker accepted $f but returned no usable name/url - nothing was posted" >&2
      exit 1
    }
    case "$url" in
      http*) full_url=$url ;;
      *) full_url="${BASE_URL}${url}" ;;
    esac
    BODY+="- [${name}](${full_url})"$'\n'
  done
fi

COMMENT_JSON=$(jq -Rs '{text: .}' <<<"$BODY")
"$YT" post "/api/issues/${ISSUE_ID}/comments" "$COMMENT_JSON"
