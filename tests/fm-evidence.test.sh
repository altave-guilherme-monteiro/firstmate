#!/usr/bin/env bash
set -u

. "tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-evidence-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

new_world() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config"
  printf '%s' "$home"
}

fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s\n' '#!/usr/bin/env bash' > "$fakebin/curl"
  cat >> "$fakebin/curl" <<'SH'
set -u
[ -z "${FM_FAKE_CURL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_CURL_LOG"
url=${*: -1}
out=""
data=""
prev=""
for a in "$@"; do
  case "$prev" in
    -o) out=$a ;;
    --data) data=$a ;;
  esac
  prev=$a
done
if [ -n "${FM_FAKE_CURL_DATA_LOG:-}" ] && [ -n "$data" ]; then
  printf '%s' "$data" >> "$FM_FAKE_CURL_DATA_LOG"
fi
case "$url" in
  *attachments*)
    printf '%s' "${FM_FAKE_ATTACH_BODY:-{\"name\":\"shot.png\",\"url\":\"/api/files/1\"}}" > "$out"
    printf '%s' "${FM_FAKE_ATTACH_CODE:-200}"
    ;;
  *comments*)
    printf '%s' "${FM_FAKE_COMMENT_BODY:-{\"id\":\"c-1\"}}" > "$out"
    printf '%s' "${FM_FAKE_COMMENT_CODE:-200}"
    ;;
  *)
    printf '%s' "${FM_FAKE_CURL_BODY:-{}}" > "$out"
    printf '%s' "${FM_FAKE_CURL_CODE:-200}"
    ;;
esac
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

hostile_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s\n' '#!/usr/bin/env bash' > "$fakebin/curl"
  cat >> "$fakebin/curl" <<'SH'
[ -z "${FM_FAKE_CURL_LOG:-}" ] || printf 'CALLED %s\n' "$*" >> "$FM_FAKE_CURL_LOG"
exit 9
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

assert_empty_file() {
  [ ! -s "$1" ] || fail "$2"
}

RECORD="$TMP_ROOT/record.txt"
HASH='#'
{
  printf '%s skipped line, not an entry\n' "$HASH"
  printf 'VAL_LOGIN_001|REQ_LOGIN|executed|QAS|user can log in\n'
  printf 'VAL_LOGIN_002|REQ_LOGIN|observed|QAS|no visual regression|Guilherme\n'
} > "$RECORD"

HOME1=$(new_world unconfigured)
FAKEBIN1=$(hostile_curl "$HOME1")
LOG1="$HOME1/curl.log"
: > "$LOG1"
out=$(PATH="$FAKEBIN1:$PATH" FM_CONFIG_OVERRIDE="$HOME1/config" FM_HOME="$HOME1" \
  FM_FAKE_CURL_LOG="$LOG1" \
  "$ROOT/bin/fm-evidence.sh" FM-1 "$RECORD" 2>&1)
expect_code 1 "$?" "unconfigured tracker refuses"
assert_contains "$out" "not configured" "refuses exactly as fm-youtrack.sh does"
assert_empty_file "$LOG1" "unconfigured tracker made no network call"

pass "unconfigured tracker: fm-evidence.sh refuses cleanly with no network call"

HOME2=$(new_world missing-record)
printf 'perm-x\n' > "$HOME2/config/youtrack-token"
out=$(FM_CONFIG_OVERRIDE="$HOME2/config" FM_HOME="$HOME2" \
  "$ROOT/bin/fm-evidence.sh" FM-1 "$TMP_ROOT/nope.txt" 2>&1)
expect_code 1 "$?" "missing record file refuses"
assert_contains "$out" "record file not found" "names the missing record file"

pass "a missing record file is refused before any tracker call"

HOME3=$(new_world bad-method)
printf 'perm-x\n' > "$HOME3/config/youtrack-token"
BAD_RECORD="$HOME3/bad.txt"
printf 'VAL_1|REQ_1|maybe|QAS|outcome\n' > "$BAD_RECORD"
out=$(FM_CONFIG_OVERRIDE="$HOME3/config" FM_HOME="$HOME3" \
  "$ROOT/bin/fm-evidence.sh" FM-1 "$BAD_RECORD" 2>&1)
expect_code 2 "$?" "unknown method refuses"
assert_contains "$out" "unknown method" "names the bad method"

pass "an unrecognized method value is refused"

HOME4=$(new_world no-observer)
printf 'perm-x\n' > "$HOME4/config/youtrack-token"
NO_OBS="$HOME4/no-obs.txt"
printf 'VAL_1|REQ_1|observed|QAS|outcome|\n' > "$NO_OBS"
out=$(FM_CONFIG_OVERRIDE="$HOME4/config" FM_HOME="$HOME4" \
  "$ROOT/bin/fm-evidence.sh" FM-1 "$NO_OBS" 2>&1)
expect_code 2 "$?" "observed entry with no observer refuses"
assert_contains "$out" "names no observer" "names the missing observer"

pass "a manual observation with no named observer is refused"

HOME5=$(new_world post-success)
printf 'perm-x\n' > "$HOME5/config/youtrack-token"
FAKEBIN5=$(fake_curl "$HOME5")
DATA5="$HOME5/data.log"
: > "$DATA5"
out=$(PATH="$FAKEBIN5:$PATH" FM_CONFIG_OVERRIDE="$HOME5/config" FM_HOME="$HOME5" \
  FM_FAKE_CURL_DATA_LOG="$DATA5" \
  "$ROOT/bin/fm-evidence.sh" FM-1 "$RECORD" 2>&1)
expect_code 0 "$?" "posting a record with no attachments succeeds"
assert_contains "$out" '"id":"c-1"' "prints the raw comment response"
assert_grep "VAL_LOGIN_001" "$DATA5" "the posted comment names the executed VAL_ id"
assert_grep "executed automatically" "$DATA5" "the posted comment records the executed method"
assert_grep "observed manually by Guilherme" "$DATA5" "the posted comment records the manual observer"
assert_grep "traces to REQ_LOGIN" "$DATA5" "the posted comment traces the REQ_ id"

pass "a clean record posts one Markdown comment covering every VAL_ entry"

HOME6=$(new_world with-attachment)
printf 'perm-x\n' > "$HOME6/config/youtrack-token"
FAKEBIN6=$(fake_curl "$HOME6")
DATA6="$HOME6/data.log"
: > "$DATA6"
SHOT="$HOME6/shot.png"
: > "$SHOT"
out=$(PATH="$FAKEBIN6:$PATH" FM_CONFIG_OVERRIDE="$HOME6/config" FM_HOME="$HOME6" \
  FM_FAKE_CURL_DATA_LOG="$DATA6" \
  "$ROOT/bin/fm-evidence.sh" FM-1 "$RECORD" --attach "$SHOT" 2>&1)
expect_code 0 "$?" "posting a record with an attachment succeeds"
assert_grep "https://altave.youtrack.cloud/api/files/1" "$DATA6" \
  "the attachment is referenced by a full URL, never a bare local path"
assert_not_contains "$(cat "$DATA6")" "$SHOT" "the local attachment path never appears in the posted comment"

pass "an uploaded attachment is referenced from the comment by its tracker URL"

HOME7=$(new_world attachment-rejected)
printf 'perm-x\n' > "$HOME7/config/youtrack-token"
FAKEBIN7=$(fake_curl "$HOME7")
LOG7="$HOME7/curl.log"
: > "$LOG7"
SHOT7="$HOME7/shot.png"
: > "$SHOT7"
out=$(PATH="$FAKEBIN7:$PATH" FM_CONFIG_OVERRIDE="$HOME7/config" FM_HOME="$HOME7" \
  FM_FAKE_CURL_LOG="$LOG7" FM_FAKE_ATTACH_CODE=400 FM_FAKE_ATTACH_BODY='{"error":"too large"}' \
  "$ROOT/bin/fm-evidence.sh" FM-1 "$RECORD" --attach "$SHOT7" 2>&1)
expect_code 1 "$?" "a rejected attachment fails the whole command"
assert_contains "$out" "tracker rejected attachment" "the rejection is reported loudly"
assert_not_contains "$(cat "$LOG7")" "comments" "no comment is posted when an attachment is rejected"

pass "a rejected attachment aborts before any comment is posted - evidence is never silently dropped"
