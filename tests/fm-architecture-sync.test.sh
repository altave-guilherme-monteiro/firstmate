#!/usr/bin/env bash
set -u

. "tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-architecture-sync-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

fm_git_identity

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config"
  printf '%s' "$home"
}

new_repo() {
  local name=$1 repo
  repo="$TMP_ROOT/repos/$name"
  mkdir -p "$repo/docs/architecture"
  git -C "$repo" init -q
  printf "Architecture Fixture\n\n\`\`\`mermaid\nflowchart TD\n  A --> B\n\`\`\`\n" > "$repo/docs/architecture/one.md"
  git -C "$repo" add docs/architecture/one.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$repo" remote add origin "git@github.com:example/one.git"
  printf '%s' "$repo"
}

fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s\n' '#!/usr/bin/env bash' > "$fakebin/curl"
  cat >> "$fakebin/curl" <<'SH'
set -u
url=${*: -1}
out=""
is_post=0
prev=""
for a in "$@"; do
  case "$prev" in
    -o) out=$a ;;
  esac
  [ "$a" != "-X" ] || is_post=1
  prev=$a
done
comments_body=${FM_FAKE_COMMENTS_BODY:-'[]'}
create_body=${FM_FAKE_CREATE_BODY:-'{"id":"c-1"}'}
update_body=${FM_FAKE_UPDATE_BODY:-'{"id":"c-1"}'}
case "$url" in
  *'/comments/'*)
    [ -z "${FM_FAKE_UPDATE_LOG:-}" ] || printf '%s\n' "CALLED $url" >> "$FM_FAKE_UPDATE_LOG"
    printf '%s' "$update_body" > "$out"
    printf '%s' "${FM_FAKE_UPDATE_CODE:-200}"
    ;;
  *'/comments?fields'*)
    if [ "$is_post" -eq 1 ]; then
      [ -z "${FM_FAKE_CREATE_LOG:-}" ] || printf '%s\n' "CALLED $url" >> "$FM_FAKE_CREATE_LOG"
      printf '%s' "$create_body" > "$out"
      printf '%s' "${FM_FAKE_CREATE_CODE:-200}"
    else
      printf '%s' "$comments_body" > "$out"
      printf '%s' "${FM_FAKE_COMMENTS_CODE:-200}"
    fi
    ;;
  *)
    printf '%s' "{}" > "$out"
    printf '%s' "200"
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

SYNC="$ROOT/bin/fm-architecture-sync.sh"

HOME1=$(new_home unconfigured)
REPO1=$(new_repo repo1)
FAKEBIN1=$(hostile_curl "$HOME1")
LOG1="$HOME1/curl.log"
: > "$LOG1"
out=$(PATH="$FAKEBIN1:$PATH" FM_CONFIG_OVERRIDE="$HOME1/config" FM_HOME="$HOME1" \
  FM_FAKE_CURL_LOG="$LOG1" \
  "$SYNC" FM-1 "$REPO1/docs/architecture/one.md" 2>&1)
expect_code 1 "$?" "unconfigured tracker refuses"
assert_contains "$out" "not configured" "refuses exactly as fm-youtrack.sh does"
assert_empty_file "$LOG1" "unconfigured tracker made no network call"

pass "unconfigured tracker: fm-architecture-sync.sh refuses cleanly with no network call"

HOME2=$(new_home missing-file)
printf 'perm-x\n' > "$HOME2/config/youtrack-token"
out=$(FM_CONFIG_OVERRIDE="$HOME2/config" FM_HOME="$HOME2" \
  "$SYNC" FM-1 "$TMP_ROOT/nope.md" 2>&1)
expect_code 1 "$?" "missing file refuses"
assert_contains "$out" "file not found" "names the missing file"

pass "a missing document file is refused before any tracker call"

HOME3=$(new_home wrong-dir)
printf 'perm-x\n' > "$HOME3/config/youtrack-token"
REPO3="$TMP_ROOT/repos/wrong-dir"
mkdir -p "$REPO3/notes"
git -C "$REPO3" init -q
printf 'not architecture\n' > "$REPO3/notes/plan.md"
git -C "$REPO3" add notes/plan.md
git -C "$REPO3" -c user.name=t -c user.email=t@example.invalid commit -qm initial
out=$(FM_CONFIG_OVERRIDE="$HOME3/config" FM_HOME="$HOME3" \
  "$SYNC" FM-1 "$REPO3/notes/plan.md" 2>&1)
expect_code 1 "$?" "a file outside docs/architecture or docs/decisions refuses"
assert_contains "$out" "not under docs/architecture" "names the contract violation"

pass "a document outside docs/architecture/ or docs/decisions/ is refused"

HOME4=$(new_home untracked)
printf 'perm-x\n' > "$HOME4/config/youtrack-token"
REPO4=$(new_repo repo4)
printf 'draft\n' > "$REPO4/docs/architecture/untracked.md"
out=$(FM_CONFIG_OVERRIDE="$HOME4/config" FM_HOME="$HOME4" \
  "$SYNC" FM-1 "$REPO4/docs/architecture/untracked.md" 2>&1)
expect_code 1 "$?" "an untracked file refuses"
assert_contains "$out" "not committed" "names the untracked file as unlanded"

pass "an untracked document is refused as unlanded content"

HOME5=$(new_home dirty)
printf 'perm-x\n' > "$HOME5/config/youtrack-token"
REPO5=$(new_repo repo5)
printf 'edited after commit\n' >> "$REPO5/docs/architecture/one.md"
out=$(FM_CONFIG_OVERRIDE="$HOME5/config" FM_HOME="$HOME5" \
  "$SYNC" FM-1 "$REPO5/docs/architecture/one.md" 2>&1)
expect_code 1 "$?" "a dirty committed file refuses"
assert_contains "$out" "uncommitted changes" "names the dirty file"

pass "a document with uncommitted changes is refused - never mirrors unlanded content"

HOME6=$(new_home first-sync)
printf 'perm-x\n' > "$HOME6/config/youtrack-token"
REPO6=$(new_repo repo6)
FAKEBIN6=$(fake_curl "$HOME6")
CREATE6="$HOME6/create.log"
UPDATE6="$HOME6/update.log"
: > "$CREATE6"
: > "$UPDATE6"
out=$(PATH="$FAKEBIN6:$PATH" FM_CONFIG_OVERRIDE="$HOME6/config" FM_HOME="$HOME6" \
  FM_FAKE_CREATE_LOG="$CREATE6" FM_FAKE_UPDATE_LOG="$UPDATE6" \
  "$SYNC" FM-1 "$REPO6/docs/architecture/one.md" --pr "https://github.com/example/one/pull/9" 2>&1)
expect_code 0 "$?" "first sync against a clean, committed, in-contract file succeeds"
assert_contains "$out" '"id":"c-1"' "prints the raw comment response"
assert_grep "CALLED" "$CREATE6" "the first sync creates a new comment"
assert_empty_file "$UPDATE6" "the first sync never calls the update endpoint"

pass "a first sync creates one mirror comment"

HOME7=$(new_home second-sync)
printf 'perm-x\n' > "$HOME7/config/youtrack-token"
REPO7=$(new_repo repo7)
FAKEBIN7=$(fake_curl "$HOME7")
CREATE7="$HOME7/create.log"
UPDATE7="$HOME7/update.log"
: > "$CREATE7"
: > "$UPDATE7"
COMMENTS_BODY7=$(printf '[{"id":"c-9","text":"<!-- fm-architecture-sync:%s:docs/architecture/one.md -->\\nold body"}]' "$REPO7")
out=$(PATH="$FAKEBIN7:$PATH" FM_CONFIG_OVERRIDE="$HOME7/config" FM_HOME="$HOME7" \
  FM_FAKE_COMMENTS_BODY="$COMMENTS_BODY7" FM_FAKE_CREATE_LOG="$CREATE7" FM_FAKE_UPDATE_LOG="$UPDATE7" \
  "$SYNC" FM-1 "$REPO7/docs/architecture/one.md" 2>&1)
expect_code 0 "$?" "a second sync against the same issue and file succeeds"
assert_grep "CALLED" "$UPDATE7" "a matching marker is updated in place"
assert_grep "/comments/c-9" "$UPDATE7" "the update targets the existing comment id"
assert_empty_file "$CREATE7" "a matching marker never creates a second comment"

pass "running the sync twice against the same issue and document updates one comment, never duplicates"
