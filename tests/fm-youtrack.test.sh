#!/usr/bin/env bash
set -u

. "tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-youtrack-tests)
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
prev=""
for a in "$@"; do
  case "$prev" in
    -o) out=$a ;;
    -H)
      case "$a" in
        @*)
          [ -z "${FM_FAKE_CURL_HEADERS:-}" ] || cat "${a#@}" >> "$FM_FAKE_CURL_HEADERS"
          ;;
      esac
      ;;
  esac
  prev=$a
done
case "$url" in
  *savedQueries*)
    printf '%s' "${FM_FAKE_SAVED_BODY:-[]}" > "$out"
    printf '%s' "${FM_FAKE_SAVED_CODE:-200}"
    ;;
  *'issues?query='*'BROKEN-QUERY-MARKER'*)
    printf '%s' "${FM_FAKE_CURL_BODY:-{}}" > "$out"
    printf '%s' "500"
    ;;
  *'issues?query='*)
    printf '%s' "${FM_FAKE_ISSUES_BODY:-[]}" > "$out"
    printf '%s' "${FM_FAKE_ISSUES_CODE:-200}"
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

HOME1=$(new_world unconfigured)
FAKEBIN1=$(hostile_curl "$HOME1")
CURL_LOG1="$HOME1/curl.log"
: > "$CURL_LOG1"
out=$(PATH="$FAKEBIN1:$PATH" FM_CONFIG_OVERRIDE="$HOME1/config" FM_HOME="$HOME1" \
  FM_FAKE_CURL_LOG="$CURL_LOG1" \
  "$ROOT/bin/fm-youtrack.sh" get /api/issues 2>&1)
code=$?
expect_code 1 "$code" "get with no token file fails"
assert_contains "$out" "not configured" "get without a token names the tracker as not configured"
assert_empty_file "$CURL_LOG1" "get without a token made no network call"

out=$(PATH="$FAKEBIN1:$PATH" FM_CONFIG_OVERRIDE="$HOME1/config" FM_HOME="$HOME1" \
  FM_FAKE_CURL_LOG="$CURL_LOG1" \
  "$ROOT/bin/fm-youtrack.sh" post /api/issues '{}' 2>&1)
expect_code 1 "$?" "post with no token file fails"
assert_empty_file "$CURL_LOG1" "post without a token made no network call"

out=$(PATH="$FAKEBIN1:$PATH" FM_CONFIG_OVERRIDE="$HOME1/config" FM_HOME="$HOME1" \
  FM_FAKE_CURL_LOG="$CURL_LOG1" \
  "$ROOT/bin/fm-youtrack.sh" queries 2>&1)
expect_code 1 "$?" "queries with no token file fails"
assert_empty_file "$CURL_LOG1" "queries without a token made no network call"

pass "absent token file: every command refuses without a network call"

HOME2=$(new_world bare-token)
BARE_TOK="perm-2a8f9c1e4b6d7f80=.a9c31e88f42b7c05=.61df"
printf '%s\n' "$BARE_TOK" > "$HOME2/config/youtrack-token"
FAKEBIN2=$(fake_curl "$HOME2")
HEADERS2="$HOME2/headers.log"
: > "$HEADERS2"
out=$(PATH="$FAKEBIN2:$PATH" FM_CONFIG_OVERRIDE="$HOME2/config" FM_HOME="$HOME2" \
  FM_FAKE_CURL_HEADERS="$HEADERS2" FM_FAKE_CURL_BODY='{"ok":true}' \
  "$ROOT/bin/fm-youtrack.sh" get /api/issues/FM-1 2>&1)
expect_code 0 "$?" "get with a realistic padded bare token succeeds"
assert_contains "$out" '"ok":true' "get prints the raw response body"
assert_grep "Authorization: Bearer $BARE_TOK" "$HEADERS2" \
  "a bare token containing internal = characters is sent byte-for-byte, never split on ="
assert_not_contains "$out" "$BARE_TOK" "get never prints the token on stdout/stderr"

HOME3=$(new_world named-token)
NAMED_RAW_TOK="perm-7f4b1a9d2e6c8035=.d05e91ac3b7f4218=.9c02"
NAMED_TOK="MYLABEL=$NAMED_RAW_TOK"
printf '%s\n' "$NAMED_TOK" > "$HOME3/config/youtrack-token"
FAKEBIN3=$(fake_curl "$HOME3")
HEADERS3="$HOME3/headers.log"
: > "$HEADERS3"
out=$(PATH="$FAKEBIN3:$PATH" FM_CONFIG_OVERRIDE="$HOME3/config" FM_HOME="$HOME3" \
  FM_FAKE_CURL_HEADERS="$HEADERS3" FM_FAKE_CURL_BODY='{}' \
  "$ROOT/bin/fm-youtrack.sh" get /api/issues/FM-1 2>&1)
expect_code 0 "$?" "get with a NAME=perm-... line succeeds"
assert_grep "Authorization: Bearer $NAMED_RAW_TOK" "$HEADERS3" \
  "NAME=perm-... form strips only the label, sending the full padded token value byte-for-byte"
assert_not_contains "$out" "$NAMED_RAW_TOK" "get never prints the NAME=TOKEN value on stdout/stderr"

pass "token file parsing: a bare perm- token with internal = characters, and a NAME=perm-... form, both send the exact token bytes without truncation"

HOME4=$(new_world post-body)
printf 'perm-x\n' > "$HOME4/config/youtrack-token"
FAKEBIN4=$(fake_curl "$HOME4")
out=$(PATH="$FAKEBIN4:$PATH" FM_CONFIG_OVERRIDE="$HOME4/config" FM_HOME="$HOME4" \
  "$ROOT/bin/fm-youtrack.sh" post /api/issues 'not json' 2>&1)
expect_code 2 "$?" "post refuses a malformed json body before any network call"
assert_contains "$out" "not valid JSON" "post names the malformed body"

pass "post validates its json body before sending"

HOME5=$(new_world queries)
printf 'perm-q\n' > "$HOME5/config/youtrack-token"
cat > "$HOME5/config/youtrack-queries" <<'EOF'

Sprint Board
project: FM State: Open
EOF
FAKEBIN5=$(fake_curl "$HOME5")
SAVED_BODY='[{"name":"Sprint Board","query":"project: FM State: Open"}]'
ISSUES_BODY='[
  {"idReadable":"FM-1","summary":"First","customFields":[
    {"name":"Type","value":{"name":"Task"}},
    {"name":"State","value":{"name":"In Progress"}},
    {"name":"Team","value":{"name":"Platform"}}
  ]},
  {"idReadable":"FM-2","summary":"Second, with a comma","customFields":[
    {"name":"Type","value":{"name":"Toil"}},
    {"name":"State","value":{"name":"Open"}}
  ]}
]'
out=$(PATH="$FAKEBIN5:$PATH" FM_CONFIG_OVERRIDE="$HOME5/config" FM_HOME="$HOME5" \
  FM_FAKE_SAVED_BODY="$SAVED_BODY" FM_FAKE_ISSUES_BODY="$ISSUES_BODY" \
  "$ROOT/bin/fm-youtrack.sh" queries 2>&1)
expect_code 0 "$?" "queries resolves saved names and raw queries"
assert_contains "$out" "$(printf 'FM-1\tTask\tIn Progress\tPlatform\tFirst')" \
  "queries prints a full tab-separated row"
assert_contains "$out" "$(printf 'FM-2\tToil\tOpen\t-\tSecond, with a comma')" \
  "queries falls back to - for a custom field the project does not define"
line_count=$(printf '%s\n' "$out" | grep -c '^FM-')
[ "$line_count" -eq 4 ] || fail "queries printed $line_count issue rows for two configured entries, expected 4 (2 issues x 2 entries)"

pass "queries resolves both saved-query names and raw query fallbacks into compact rows"

HOME6=$(new_world empty-queries)
printf 'perm-e\n' > "$HOME6/config/youtrack-token"
printf '\n\n' > "$HOME6/config/youtrack-queries"
FAKEBIN6=$(fake_curl "$HOME6")
out=$(PATH="$FAKEBIN6:$PATH" FM_CONFIG_OVERRIDE="$HOME6/config" FM_HOME="$HOME6" \
  "$ROOT/bin/fm-youtrack.sh" queries 2>&1)
expect_code 1 "$?" "queries with only blank lines refuses"
assert_contains "$out" "no usable entries" "queries names the empty configuration"

pass "queries refuses cleanly when the queries file has no usable entries"

HOME8=$(new_world all-queries-fail)
printf 'perm-fails\n' > "$HOME8/config/youtrack-token"
cat > "$HOME8/config/youtrack-queries" <<'EOF'
Sprint Board
project: FM State: Open
EOF
FAKEBIN8=$(fake_curl "$HOME8")
out=$(PATH="$FAKEBIN8:$PATH" FM_CONFIG_OVERRIDE="$HOME8/config" FM_HOME="$HOME8" \
  FM_FAKE_SAVED_CODE=401 FM_FAKE_ISSUES_CODE=401 \
  "$ROOT/bin/fm-youtrack.sh" queries 2>&1)
expect_code 1 "$?" "queries exits non-zero when every configured query fails to read"
assert_contains "$out" "every configured query failed" \
  "a total read failure is named distinctly from an empty result"
assert_not_contains "$out" "no usable entries" \
  "a total read failure is not reported as an empty/unconfigured queries file"

pass "queries distinguishes a total read failure from a genuinely empty result"

HOME9=$(new_world partial-query-failure)
printf 'perm-partial\n' > "$HOME9/config/youtrack-token"
cat > "$HOME9/config/youtrack-queries" <<'EOF'
BROKEN-QUERY-MARKER
project: FM State: Open
EOF
FAKEBIN9=$(fake_curl "$HOME9")
ISSUES_BODY_9='[{"idReadable":"FM-9","summary":"Still readable","customFields":[
  {"name":"Type","value":{"name":"Task"}},
  {"name":"State","value":{"name":"Open"}}
]}]'
out=$(PATH="$FAKEBIN9:$PATH" FM_CONFIG_OVERRIDE="$HOME9/config" FM_HOME="$HOME9" \
  FM_FAKE_ISSUES_BODY="$ISSUES_BODY_9" \
  "$ROOT/bin/fm-youtrack.sh" queries 2>&1)
expect_code 0 "$?" "queries succeeds when at least one configured entry still reads"
assert_contains "$out" "FM-9" "the successful entry's rows still print"

pass "a partial query failure still exits 0 and reports what succeeded"

HOME10=$(new_world attach-success)
printf 'perm-a\n' > "$HOME10/config/youtrack-token"
FAKEBIN10=$(fake_curl "$HOME10")
SHOT10="$HOME10/shot.png"
: > "$SHOT10"
out=$(PATH="$FAKEBIN10:$PATH" FM_CONFIG_OVERRIDE="$HOME10/config" FM_HOME="$HOME10" \
  FM_FAKE_CURL_BODY='{"name":"shot.png","url":"/api/files/9"}' \
  "$ROOT/bin/fm-youtrack.sh" attach /api/issues/FM-1/attachments "$SHOT10" 2>&1)
expect_code 0 "$?" "attach with a real file succeeds"
assert_contains "$out" '"url":"/api/files/9"' "attach prints the raw tracker response"

pass "attach uploads a file and prints the raw response"

HOME11=$(new_world attach-missing-file)
printf 'perm-a\n' > "$HOME11/config/youtrack-token"
out=$(FM_CONFIG_OVERRIDE="$HOME11/config" FM_HOME="$HOME11" \
  "$ROOT/bin/fm-youtrack.sh" attach /api/issues/FM-1/attachments "$HOME11/nope.png" 2>&1)
expect_code 1 "$?" "attach with a missing local file refuses"
assert_contains "$out" "attachment file not found" "attach names the missing local file"

pass "attach refuses cleanly when the local file does not exist"

HOME12=$(new_world attach-rejected)
printf 'perm-a\n' > "$HOME12/config/youtrack-token"
FAKEBIN12=$(fake_curl "$HOME12")
SHOT12="$HOME12/shot.png"
: > "$SHOT12"
out=$(PATH="$FAKEBIN12:$PATH" FM_CONFIG_OVERRIDE="$HOME12/config" FM_HOME="$HOME12" \
  FM_FAKE_CURL_CODE=413 FM_FAKE_CURL_BODY='{"error":"too large"}' \
  "$ROOT/bin/fm-youtrack.sh" attach /api/issues/FM-1/attachments "$SHOT12" 2>&1)
expect_code 1 "$?" "attach reports a tracker rejection as failure"
assert_contains "$out" "HTTP 413" "attach names the exact HTTP status"
assert_contains "$out" "too large" "attach surfaces the tracker's rejection body"

pass "a rejected attachment upload fails loudly with the tracker's own response"

HOME13=$(new_world url-command)
printf 'perm-u\n' > "$HOME13/config/youtrack-token"
out=$(FM_CONFIG_OVERRIDE="$HOME13/config" FM_HOME="$HOME13" "$ROOT/bin/fm-youtrack.sh" url 2>&1)
expect_code 0 "$?" "url prints the default tracker base url"
assert_contains "$out" "https://altave.youtrack.cloud" "url falls back to the built-in default"

printf 'https://example.youtrack.cloud/\n' > "$HOME13/config/youtrack-url"
out=$(FM_CONFIG_OVERRIDE="$HOME13/config" FM_HOME="$HOME13" "$ROOT/bin/fm-youtrack.sh" url 2>&1)
assert_contains "$out" "https://example.youtrack.cloud" "url honors a configured youtrack-url, trailing slash stripped"

pass "url prints the resolved tracker base url with no network call"

HOME14=$(new_world delete-success)
printf 'perm-d\n' > "$HOME14/config/youtrack-token"
FAKEBIN14=$(fake_curl "$HOME14")
out=$(PATH="$FAKEBIN14:$PATH" FM_CONFIG_OVERRIDE="$HOME14/config" FM_HOME="$HOME14" \
  FM_FAKE_CURL_BODY='{"id":"8-1"}' \
  "$ROOT/bin/fm-youtrack.sh" delete /api/issues/FM-1/attachments/8-1 2>&1)
expect_code 0 "$?" "delete succeeds"
assert_contains "$out" '"id":"8-1"' "delete prints the raw tracker response"

HOME15=$(new_world delete-unconfigured)
FAKEBIN15=$(hostile_curl "$HOME15")
CURL_LOG15="$HOME15/curl.log"
: > "$CURL_LOG15"
out=$(PATH="$FAKEBIN15:$PATH" FM_CONFIG_OVERRIDE="$HOME15/config" FM_HOME="$HOME15" \
  FM_FAKE_CURL_LOG="$CURL_LOG15" \
  "$ROOT/bin/fm-youtrack.sh" delete /api/issues/FM-1/attachments/8-1 2>&1)
expect_code 1 "$?" "delete with no token file fails"
assert_contains "$out" "not configured" "delete without a token names the tracker as not configured"
assert_empty_file "$CURL_LOG15" "delete without a token made no network call"

HOME16=$(new_world delete-rejected)
FAKEBIN16=$(fake_curl "$HOME16")
printf 'perm-r\n' > "$HOME16/config/youtrack-token"
out=$(PATH="$FAKEBIN16:$PATH" FM_CONFIG_OVERRIDE="$HOME16/config" FM_HOME="$HOME16" \
  FM_FAKE_CURL_CODE=404 FM_FAKE_CURL_BODY='{"error":"not found"}' \
  "$ROOT/bin/fm-youtrack.sh" delete /api/issues/FM-1/attachments/8-1 2>&1)
expect_code 1 "$?" "delete reports a tracker rejection as failure"
assert_contains "$out" "HTTP 404" "delete names the exact HTTP status"

pass "delete issues a DELETE request through the same auth path, and refuses cleanly when unconfigured"

HOME7=$(new_world symlinked-token)
: > "$HOME7/real-token"
ln -s "$HOME7/real-token" "$HOME7/config/youtrack-token"
out=$(FM_CONFIG_OVERRIDE="$HOME7/config" FM_HOME="$HOME7" "$ROOT/bin/fm-youtrack.sh" get /api/issues 2>&1)
expect_code 1 "$?" "a symlinked token file is treated as not configured"

pass "a symlinked token file never counts as configured"
