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
--attach <path>  a screenshot or artifact file to upload to the comment and
               render inline in its text; repeatable. The file is never
               left as a bare path in the comment text.

Behavior:
  YouTrack only binds an attachment to a comment - visible in that
  comment's own attachments and safe to find later - when the attachment is
  uploaded to that comment's own attachment endpoint, after the comment
  already exists. Uploading to the ISSUE's attachment endpoint instead
  produces an orphan: a file sitting on the issue, unlisted by any comment,
  that outlives the comment if the comment is later deleted or superseded.
  So this script posts the record text first, then uploads every --attach
  to that comment's attachment endpoint, then updates the same comment's
  text to reference each attachment inline (an image renders inline in
  YouTrack's Markdown; any other file type links to it).

  If any attachment upload fails after the comment was created, this
  script deletes that comment immediately and exits non-zero, naming the
  tracker's exact rejection - it never leaves a comment on the issue that
  promised evidence it does not carry.

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

if [ "${#ATTACH_PATHS[@]}" -eq 0 ]; then
  COMMENT_JSON=$(jq -Rs '{text: .}' <<<"$BODY")
  "$YT" post "/api/issues/${ISSUE_ID}/comments?fields=id,text" "$COMMENT_JSON"
  exit "$?"
fi

CREATE_JSON=$(jq -Rs '{text: .}' <<<"$BODY")
CREATE_RESP=$("$YT" post "/api/issues/${ISSUE_ID}/comments?fields=id,text" "$CREATE_JSON") \
  || { echo "fm-evidence: could not create the evidence comment - nothing was posted" >&2; exit 1; }
COMMENT_ID=$(printf '%s' "$CREATE_RESP" | jq -r '.id // empty')
[ -n "$COMMENT_ID" ] || {
  echo "fm-evidence: tracker accepted the comment but returned no id - cannot attach to it" >&2
  exit 1
}

rollback() {
  "$YT" post "/api/issues/${ISSUE_ID}/comments/${COMMENT_ID}" '{"deleted":true}' >/dev/null 2>&1
}

BASE_URL=$("$YT" url) || { rollback; echo "fm-evidence: tracker not configured" >&2; exit 1; }
BODY+=$'\n'"**Attachments:**"$'\n'
for f in "${ATTACH_PATHS[@]}"; do
  resp=$("$YT" attach "/api/issues/${ISSUE_ID}/comments/${COMMENT_ID}/attachments?fields=id,name,url" "$f") || {
    rollback
    echo "fm-evidence: tracker rejected attachment $f - the evidence comment was rolled back, nothing was posted" >&2
    exit 1
  }
  name=$(printf '%s' "$resp" | jq -r '(if type == "array" then .[0] else . end).name // empty')
  url=$(printf '%s' "$resp" | jq -r '(if type == "array" then .[0] else . end).url // empty')
  [ -n "$name" ] && [ -n "$url" ] || {
    rollback
    echo "fm-evidence: tracker accepted $f but returned no usable name/url - the evidence comment was rolled back, nothing was posted" >&2
    exit 1
  }
  case "$url" in
    http*) full_url=$url ;;
    *) full_url="${BASE_URL}${url}" ;;
  esac
  case "$name" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.PNG|*.JPG|*.JPEG|*.GIF|*.WEBP)
      BODY+="![${name}](${full_url})"$'\n'
      ;;
    *)
      BODY+="- [${name}](${full_url})"$'\n'
      ;;
  esac
done

UPDATE_JSON=$(jq -Rs '{text: .}' <<<"$BODY")
"$YT" post "/api/issues/${ISSUE_ID}/comments/${COMMENT_ID}?fields=id,text,attachments(name,url)" "$UPDATE_JSON"
