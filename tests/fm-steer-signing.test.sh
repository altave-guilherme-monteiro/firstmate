#!/usr/bin/env bash
# tests/fm-steer-signing.test.sh - opt-in HMAC signing of steering-inbox records
# (bin/fm-task-inbox-lib.sh "Steer signing") and its verifier
# (bin/fm-verify-steer.sh), driven through the real executables.
#   1. Without config/steer-signing a record carries no sig and no key appears.
#   2. With it, a record carries a sig, the key is private, and the verifier
#      prints VERIFIED and the exact body, including trailing newlines.
#   3. An edited body is TAMPERED, a stripped sig is UNSIGNED, a lost key is
#      UNSIGNED, and a record moved to handled/ still verifies.
#   4. The idempotent enqueue still dedups an exact-body re-run when signing.
#   5. A write that cannot sign fails and leaves no record.
#   6. A brief carries the verify instruction only while the flag is present.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-steer-signing)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
VERIFY="$ROOT/bin/fm-verify-steer.sh"

new_home() {  # <name> [signing]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  [ "${2:-}" != signing ] || : > "$home/config/steer-signing"
  printf '%s' "$home"
}

enqueue() {  # <home> <function> <text>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/fm-task-inbox-lib.sh"
    "$2" "$3/state" t1 "$4"
  ' _ "$ROOT" "$2" "$1" "$3"
}

test_unsigned_by_default() {
  local home rec
  home=$(new_home off)
  rec=$(enqueue "$home" fm_task_inbox_write "plain") || fail "write failed"
  grep -q '^sig=' "$rec" && fail "a record carried a sig without the flag"
  [ ! -e "$home/state/.steer-key" ] || fail "a key was created without the flag"
  "$VERIFY" "$rec" >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unsigned record should exit 2"
  pass "steer signing: off by default, records stay unsigned"
}

test_signed_record_verifies_with_exact_body() {
  local home rec text mode
  home=$(new_home on signing)
  text=$'line one\n\nlast line\n\n'
  rec=$(enqueue "$home" fm_task_inbox_write "$text") || fail "write failed"
  grep -q '^sig=[0-9a-f]\{64\}$' "$rec" || fail "record has no 64-hex sig"
  mode=$(stat -c %a "$home/state/.steer-key" 2>/dev/null || stat -f %Lp "$home/state/.steer-key")
  [ "$mode" = 600 ] || fail "key mode is $mode, expected 600"
  "$VERIFY" "$rec" | grep -q '^VERIFIED' || fail "signed record did not verify"
  "$VERIFY" --body "$rec" > "$home/body.out" || fail "--body failed"
  printf '%s' "$text" | cmp -s - "$home/body.out" || fail "--body did not return the exact body"
  pass "steer signing: signed record verifies and returns the exact body"
}

test_tamper_strip_and_key_loss() {
  local home rec status
  home=$(new_home tamper signing)
  rec=$(enqueue "$home" fm_task_inbox_write "do the safe thing") || fail "write failed"
  cp "$rec" "$home/orig.msg"
  sed 's/safe/unsafe/' "$home/orig.msg" > "$rec"
  "$VERIFY" "$rec" >/dev/null 2>&1; status=$?
  [ "$status" -eq 3 ] || fail "edited body should exit 3, got $status"
  grep -v '^sig=' "$home/orig.msg" > "$rec"
  "$VERIFY" "$rec" >/dev/null 2>&1; status=$?
  [ "$status" -eq 2 ] || fail "stripped sig should exit 2, got $status"
  cp "$home/orig.msg" "$rec"
  rm "$home/state/.steer-key"
  "$VERIFY" "$rec" >/dev/null 2>&1; status=$?
  [ "$status" -eq 2 ] || fail "missing key should exit 2, got $status"
  pass "steer signing: edited body is TAMPERED, stripped sig or lost key is UNSIGNED"
}

test_handled_record_still_verifies() {
  local home rec
  home=$(new_home handled signing)
  rec=$(enqueue "$home" fm_task_inbox_write "ack me") || fail "write failed"
  mv "$rec" "$home/state/t1.inbox/handled/"
  "$VERIFY" "$home/state/t1.inbox/handled/${rec##*/}" | grep -q '^VERIFIED' \
    || fail "a handled record did not verify"
  pass "steer signing: a record in handled/ still verifies"
}

test_idempotent_write_still_dedups() {
  local home first second count
  home=$(new_home idem signing)
  first=$(enqueue "$home" fm_task_inbox_write_idempotent "retry me") || fail "first write failed"
  second=$(enqueue "$home" fm_task_inbox_write_idempotent "retry me") || fail "second write failed"
  [ "$first" = "$second" ] || fail "idempotent re-run made a new record"
  count=$(find "$home/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l)
  [ "$count" -eq 1 ] || fail "expected one record, found $count"
  pass "steer signing: idempotent enqueue still dedups signed records"
}

test_unsignable_write_fails_closed() {
  local home fake
  home=$(new_home nosign signing)
  fake="$TMP_ROOT/fakebin"
  mkdir -p "$fake"
  printf '#!/bin/sh\nexit 1\n' > "$fake/openssl"
  chmod +x "$fake/openssl"
  PATH="$fake:$PATH" enqueue "$home" fm_task_inbox_write "must not land" >/dev/null 2>&1 \
    && fail "a write that cannot sign succeeded"
  [ -z "$(find "$home/state/t1.inbox" -name '*.msg' 2>/dev/null)" ] \
    || fail "an unsignable write left a record"
  pass "steer signing: a write that cannot sign fails and leaves no record"
}

test_brief_mentions_verifier_only_when_enabled() {
  local off on
  off=$(new_home brief-off)
  on=$(new_home brief-on signing)
  FM_HOME="$off" "$ROOT/bin/fm-brief.sh" brief-off some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "brief scaffold failed without the flag"
  FM_HOME="$on" "$ROOT/bin/fm-brief.sh" brief-on some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "brief scaffold failed with the flag"
  grep -q 'fm-verify-steer.sh' "$off/data/brief-off/brief.md" && fail "brief names the verifier without the flag"
  grep -q 'fm-verify-steer.sh' "$on/data/brief-on/brief.md" || fail "brief omits the verifier with the flag"
  pass "steer signing: the brief names the verifier only while the flag is set"
}

fm_test_run \
  test_unsigned_by_default \
  test_signed_record_verifies_with_exact_body \
  test_tamper_strip_and_key_loss \
  test_handled_record_still_verifies \
  test_idempotent_write_still_dedups \
  test_unsignable_write_fails_closed \
  test_brief_mentions_verifier_only_when_enabled
