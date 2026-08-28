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
BARE_TOK="perm-bareA1"
printf '%s\n' "$BARE_TOK" > "$HOME2/config/youtrack-token"
FAKEBIN2=$(fake_curl "$HOME2")
HEADERS2="$HOME2/headers.log"
: > "$HEADERS2"
out=$(PATH="$FAKEBIN2:$PATH" FM_CONFIG_OVERRIDE="$HOME2/config" FM_HOME="$HOME2" \
  FM_FAKE_CURL_HEADERS="$HEADERS2" FM_FAKE_CURL_BODY='{"ok":true}' \
  "$ROOT/bin/fm-youtrack.sh" get /api/issues/FM-1 2>&1)
expect_code 0 "$?" "get with a bare token succeeds"
assert_contains "$out" '"ok":true' "get prints the raw response body"
assert_grep "Authorization: Bearer $BARE_TOK" "$HEADERS2" \
  "bare token line is sent as the bearer header"
assert_not_contains "$out" "$BARE_TOK" "get never prints the token on stdout/stderr"

HOME3=$(new_world named-token)
NAMED_TOK="perm-namedB2"
printf 'MYLABEL=%s\n' "$NAMED_TOK" > "$HOME3/config/youtrack-token"
FAKEBIN3=$(fake_curl "$HOME3")
HEADERS3="$HOME3/headers.log"
: > "$HEADERS3"
out=$(PATH="$FAKEBIN3:$PATH" FM_CONFIG_OVERRIDE="$HOME3/config" FM_HOME="$HOME3" \
  FM_FAKE_CURL_HEADERS="$HEADERS3" FM_FAKE_CURL_BODY='{}' \
  "$ROOT/bin/fm-youtrack.sh" get /api/issues/FM-1 2>&1)
expect_code 0 "$?" "get with a NAME=token line succeeds"
assert_grep "Authorization: Bearer $NAMED_TOK" "$HEADERS3" \
  "NAME=TOKEN form strips the label and sends only the token value"
assert_not_contains "$out" "$NAMED_TOK" "get never prints the NAME=TOKEN value on stdout/stderr"

pass "token file parsing: bare and NAME=TOKEN forms both authenticate without leaking"

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

HOME7=$(new_world symlinked-token)
: > "$HOME7/real-token"
ln -s "$HOME7/real-token" "$HOME7/config/youtrack-token"
out=$(FM_CONFIG_OVERRIDE="$HOME7/config" FM_HOME="$HOME7" "$ROOT/bin/fm-youtrack.sh" get /api/issues 2>&1)
expect_code 1 "$?" "a symlinked token file is treated as not configured"

pass "a symlinked token file never counts as configured"
