#!/usr/bin/env bash
# fm-hold-spec-lib.sh - the one owner of the typed hold spec (fm-hold-v2).
#
# A captain hold may carry a typed spec: one or more questions, each with its
# options, at most one recommendation, and the triage fields that sort it into
# a quadrant. bin/fm-captain-hold.sh stores the spec as one line in the held
# task's body (`Hold spec (fm-hold-v2): <compact json>`) and reads it back
# through this library. docs/decisions/0001-decisions-and-work-panels.md owns
# the triage table and the never-auto classes.
#
# Input spec (JSON object):
#   kind        question | approval | action
#   origin      optional task id of the worker that raised the call
#   issue       optional tracker issue key
#   watch_key   optional status key of the origin; a resolved line for it
#               marks the call as answered by events
#   links       optional list of URLs
#   questions   non-empty list of {id, text, options, recommendation, class,
#               undo_cost, blocks, deadline, quadrant_override, reason,
#               context, details}
# A question's context is one line of at most 300 characters that the panel
# shows under the options. A question's details is an object of three optional
# parts: text (list of paragraphs), table (list of rows, the first row is the
# header, every row a list of strings), and links (list of [label, url] pairs).
# The panel shows details in a section that opens on request.
# A question's class is none, merge, delete, credential, outward, or money.
# Its undo_cost is minutes, hours, days, or irreversible. A class other than
# none, and an undo_cost of irreversible, make it a never-auto question.
#
# The library adds the computed fields: created, updated, and per question
# quadrant, ttl_at, and status (open, applied, or answered).
#
# Functions (all print JSON or TSV rows on stdout; a refusal prints one line
# on stderr and returns 1; times are UTC YYYY-MM-DDTHH:MM:SSZ strings):
#   fm_hold_spec_now_iso
#       The current time, or FM_CAPTAIN_HOLD_NOW when set.
#   fm_hold_spec_normalize <spec-json> <now-iso>
#       Validates the spec and adds the computed fields.
#   fm_hold_spec_refresh <spec-json> <now-iso>
#       Recomputes quadrant and ttl_at of every open question, so a nearing
#       deadline moves it.
#   fm_hold_spec_due <spec-json> <now-iso>
#       One row per open question whose ttl_at has passed:
#       <question>\t<quadrant>\t<ttl_at>\t<bucket>. The bucket counts the
#       elapsed periods, so a repeat reminder gets a new bucket.
#   fm_hold_spec_apply_auto <spec-json> <question-id> <now-iso>
#       Records the recommendation of a quadrant 3 or 4 question with a veto time.
#   fm_hold_spec_apply_answer <spec-json> <question-id> <option-id|-> <note> <now-iso>
#       Records the user's answer to one question.
#   fm_hold_spec_open_count <spec-json>
#       The number of questions still open.
#   fm_hold_spec_summary <spec-json>
#       One decision line per question, for the record that closes the task.
#   fm_hold_spec_line <spec-json>
#       The task body line that stores the spec.
#   fm_hold_spec_extract <decoded-task-body>
#       The stored spec JSON, or nothing when the body carries none.
#
# Source this file; it defines functions only.

FM_HOLD_SPEC_PREFIX='Hold spec (fm-hold-v2): '
FM_HOLD_SPEC_VETO_SECONDS=86400

FM_HOLD_SPEC_JQ_DEFS=$(cat <<'JQ'
def urgent_window: 172800;
def now_period: 14400;
def week_period: 259200;
def auto_period: 86400;
def max_text: 300;
def never_auto: ((.class // "none") != "none") or ((.undo_cost // "") == "irreversible");
def important: never_auto or ((.undo_cost // "") | IN("days","irreversible")) or (.recommendation == null);
def urgent($now): (((.blocks // []) | length) > 0)
  or (.deadline != null and ((.deadline | fromdateiso8601) - $now) < urgent_window);
def computed_quadrant($now):
  if important then (if urgent($now) then 1 else 2 end)
  else (if urgent($now) then 3 else 4 end) end;
def quadrant($now): (.quadrant_override // computed_quadrant($now));
def period($q):
  if $q == 1 then now_period
  elif $q == 2 then week_period
  else auto_period end;
def ttl($created; $q): (($created | fromdateiso8601) + period($q)) | todateiso8601;
def slug: type == "string" and test("^[A-Za-z0-9._-]+$");
def refuse($m): error($m);
def string_list: type == "array" and all(.[]; type == "string");
def valid_details:
  type == "object"
  and ((.text // []) | string_list)
  and ((.table // []) | type == "array" and all(.[]; string_list))
  and ((.links // []) | type == "array" and all(.[]; type == "array" and length == 2 and string_list));
def validate_question($kind):
  (if (.id | slug) then . else refuse("question id must be a slug") end)
  | (if (.text | type) == "string" and (.text | length) > 0 and (.text | length) <= max_text and (.text | test("[\n\r]") | not)
     then . else refuse("question \(.id): text must be one line of at most \(max_text) characters; hold one question per entry, not a topic list") end)
  | (if (.text | [match("\\?"; "g")] | length) <= 1
     then . else refuse("question \(.id): text holds more than one question; split it into one entry per question") end)
  | (if (.class // null) | IN("none","merge","delete","credential","outward","money")
     then . else refuse("question \(.id): class must be none, merge, delete, credential, outward, or money") end)
  | (if (.undo_cost // null) | IN("minutes","hours","days","irreversible")
     then . else refuse("question \(.id): undo_cost must be minutes, hours, days, or irreversible") end)
  | (if ((.options // []) | type) == "array" and all((.options // [])[]; (.id | slug) and ((.label // "") | type == "string" and length > 0))
     then . else refuse("question \(.id): every option needs a slug id and a label") end)
  | (if $kind != "question" or ((.options // []) | length) >= 2
     then . else refuse("question \(.id): a question needs at least two options") end)
  | . as $question
  | (if (.recommendation // null) == null or (($question.options // []) | map(.id) | index($question.recommendation)) != null
     then . else refuse("question \(.id): recommendation must name one option id") end)
  | (if (.context // null) == null or ((.context | type) == "string" and (.context | length) <= max_text and (.context | test("[\n\r]") | not))
     then . else refuse("question \(.id): context must be one line of at most \(max_text) characters") end)
  | (if (.details // null) == null or (.details | valid_details)
     then . else refuse("question \(.id): details must hold text as a list of strings, table as a list of string rows, and links as [label, url] pairs") end)
  | (if (.deadline // null) == null or ((.deadline | type) == "string" and (.deadline | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
     then . else refuse("question \(.id): deadline must be a UTC YYYY-MM-DDTHH:MM:SSZ time") end)
  | (if ((.blocks // []) | type) == "array" and all((.blocks // [])[]; slug)
     then . else refuse("question \(.id): blocks must list task id slugs") end)
  | (if (.quadrant_override // null) == null
        or (((.quadrant_override | IN(1,2,3,4)) and ((.reason // "") | type == "string" and length > 0)))
     then . else refuse("question \(.id): quadrant_override needs a value from 1 to 4 and a reason") end);
def normalize_question($now; $created):
  .options = (.options // [])
  | .context = (.context // null)
  | .details = (.details // null)
  | .recommendation = (.recommendation // null)
  | .blocks = (.blocks // [])
  | .deadline = (.deadline // null)
  | .quadrant = quadrant($now)
  | (if .quadrant >= 3 and (never_auto or .recommendation == null)
     then refuse("question \(.id): a never-auto class or a missing recommendation can not reach quadrant 3 or 4")
     else . end)
  | .ttl_at = ttl($created; .quadrant)
  | .status = (.status // "open");
JQ
)

fm_hold_spec_now_iso() {
  printf '%s' "${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

fm_hold_spec_refusal_line() {
  sed -n 's/^jq: error ([^)]*): //p' | sed 's/ (while parsing.*$//; s/ at <[^>]*>.*$//' | head -1
}

fm_hold_spec_normalize() {
  local spec=$1 now=$2 out
  out=$(printf '%s' "$spec" | jq -c --arg now "$now" "$FM_HOLD_SPEC_JQ_DEFS"'
    ($now | fromdateiso8601) as $n
    | (if type == "object" then . else refuse("the spec must be a JSON object") end)
    | (if (.kind // null) | IN("question","approval","action") then . else refuse("kind must be question, approval, or action") end)
    | (if (.questions | type) == "array" and (.questions | length) > 0 then . else refuse("the spec needs at least one question") end)
    | (if ((.questions | map(.id) | unique | length) == (.questions | length)) then . else refuse("question ids must be unique") end)
    | .kind as $kind
    | (.questions |= map(validate_question($kind)))
    | .schema = "fm-hold-v2"
    | .created = (.created // $now)
    | .updated = $now
    | .links = (.links // [])
    | .origin = (.origin // null)
    | .issue = (.issue // null)
    | .watch_key = (.watch_key // null)
    | .created as $created
    | .questions |= map(normalize_question($n; $created))
    | {schema, kind, origin, issue, watch_key, links, created, updated, questions}
  ' 2>&1) || {
    printf '%s\n' "$out" | fm_hold_spec_refusal_line >&2
    return 1
  }
  printf '%s\n' "$out"
}

fm_hold_spec_refresh() {
  printf '%s' "$1" | jq -c --arg now "$2" "$FM_HOLD_SPEC_JQ_DEFS"'
    ($now | fromdateiso8601) as $n
    | .created as $created
    | .questions |= map(
        if .status == "open" then
          .quadrant = quadrant($n) | .ttl_at = ttl($created; .quadrant)
        else . end)
  '
}

fm_hold_spec_due() {
  printf '%s' "$1" | jq -r --arg now "$2" "$FM_HOLD_SPEC_JQ_DEFS"'
    ($now | fromdateiso8601) as $n
    | .created as $created
    | .questions[]
    | select(.status == "open")
    | .quadrant as $q
    | select(($created | fromdateiso8601) + (if $q >= 3 then 0 else period($q) end) <= $n)
    | [.id, $q, .ttl_at, ((($n - ($created | fromdateiso8601)) / period($q)) | floor)] | @tsv
  '
}

fm_hold_spec_apply_auto() {
  local out
  out=$(printf '%s' "$1" | jq -c --arg q "$2" --arg now "$3" --argjson veto "$FM_HOLD_SPEC_VETO_SECONDS" "$FM_HOLD_SPEC_JQ_DEFS"'
    ($now | fromdateiso8601) as $n
    | (if any(.questions[]; .id == $q) then . else refuse("no question \($q) in this hold") end)
    | .questions |= map(
        if .id != $q then .
        else
          (if .status == "open" then . else refuse("question \($q) is already \(.status)") end)
          | (if never_auto then refuse("question \($q) is in a never-auto class; only the user decides it") else . end)
          | (if .recommendation == null then refuse("question \($q) has no recommendation to apply") else . end)
          | .quadrant = quadrant($n)
          | (if .quadrant >= 3 then . else refuse("question \($q) is in quadrant \(.quadrant); only quadrant 3 or 4 can be applied") end)
          | .status = "applied" | .mode = "auto" | .decision = .recommendation
          | .rule = "quadrant-\(.quadrant)-recommendation"
          | .decided_at = $now
          | .veto_until = (($n + $veto) | todateiso8601)
        end)
    | .updated = $now
  ' 2>&1) || {
    printf '%s\n' "$out" | fm_hold_spec_refusal_line >&2
    return 1
  }
  printf '%s\n' "$out"
}

fm_hold_spec_apply_answer() {
  local out
  out=$(printf '%s' "$1" | jq -c --arg q "$2" --arg opt "$3" --arg note "$4" --arg now "$5" "$FM_HOLD_SPEC_JQ_DEFS"'
    (if any(.questions[]; .id == $q) then . else refuse("no question \($q) in this hold") end)
    | .questions |= map(
        if .id != $q then .
        else
          (if .status == "answered" then refuse("question \($q) is already answered") else . end)
          | (if $opt == "-" or ((.options | map(.id)) | index($opt)) != null then . else refuse("question \($q) has no option \($opt)") end)
          | (if $opt == "-" and $note == "" then refuse("an answer needs an option or a note") else . end)
          | .status = "answered" | .mode = "user"
          | .decision = (if $opt == "-" then $note else $opt end)
          | .note = $note
          | .decided_at = $now
          | del(.veto_until)
        end)
    | .updated = $now
  ' 2>&1) || {
    printf '%s\n' "$out" | fm_hold_spec_refusal_line >&2
    return 1
  }
  printf '%s\n' "$out"
}

fm_hold_spec_open_count() {
  printf '%s' "$1" | jq -r '[.questions[] | select(.status == "open")] | length'
}

fm_hold_spec_summary() {
  printf '%s' "$1" | jq -r '
    .questions[]
    | "\(.id): \(.decision // "none") (\(.mode // "none")\(if .veto_until then ", veto until \(.veto_until)" else "" end))"
  '
}

fm_hold_spec_line() {
  printf '%s%s' "$FM_HOLD_SPEC_PREFIX" "$(printf '%s' "$1" | jq -c .)"
}

fm_hold_spec_extract() {
  printf '%s\n' "$1" | sed -n 's/^Hold spec (fm-hold-v2): //p' | head -1
}
