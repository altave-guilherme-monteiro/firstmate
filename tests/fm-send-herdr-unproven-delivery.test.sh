#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

herdr_forget_inherited_pane

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-herdr-unproven)

ambiguous_geometry_composer_box() {
  printf '  \xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n  \xe2\x94\x82 \xe2\x9d\xaf hello captain        \xe2\x94\x82\n   \xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 Composer \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\n\n  Enter:send\n'
}

make_herdr_fakebin() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

run_send() {
  local dir=$1 fb resp home
  fb=$(make_herdr_fakebin "$dir")
  resp="$dir/responses"; mkdir -p "$resp"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  ambiguous_geometry_composer_box > "$resp/6.out"
  home="$dir/home"; mkdir -p "$home/state"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_HERDR_LOG="$dir/log" FM_HERDR_RESPONSES="$resp" \
    FM_SEND_RETRIES=1 FM_SEND_SETTLE=0 \
    FM_BACKEND_HERDR_SUBMIT_POLLS=1 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    "$SEND" "default:w1:p2" "hello captain"
}

test_pending_unproven_is_not_reported_as_failed() {
  local dir out rc
  dir="$TMP_ROOT/unproven"; mkdir -p "$dir"
  out=$(run_send "$dir" 2>&1); rc=$?
  expect_code 3 "$rc" "a pending-unproven herdr delivery must exit with the documented unconfirmed status (3), not a hard failure"
  assert_contains "$out" "verdict=pending-unproven" "expected the unproven verdict to be named in the message"
  assert_contains "$out" "unconfirmed" "expected the unconfirmed wording, not a failure claim"
  assert_not_contains "$out" "error: text not submitted" "a pending-unproven delivery must not be reported with the hard-failure error text"
  pass "fm-send: a herdr pending-unproven delivery is reported as unconfirmed, not failed"
}

test_pending_unproven_is_not_reported_as_failed
