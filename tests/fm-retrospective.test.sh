#!/usr/bin/env bash
set -u

. "tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-retrospective-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

new_world() {
  local name=$1 w home root fakebin
  w="$TMP_ROOT/$name"
  home="$w/home"
  root="$w/root"
  mkdir -p "$home/config" "$home/data" "$home/state" "$root/bin"
  local f
  for f in "$ROOT"/bin/*.sh; do
    ln -s "$f" "$root/bin/$(basename "$f")"
  done
  rm -f "$root/bin/fm-youtrack.sh"
  fakebin=$(fm_fakebin "$w")
  printf '%s|%s|%s\n' "$home" "$root" "$fakebin"
}

split_triple() { IFS='|' read -r H R FB <<<"$1"; }

stub_no_tools() {
  local fakebin=$1
  rm -f "$fakebin"/gh-axi "$fakebin"/quota-axi
}

write_stub() {
  local path=$1 body=$2
  printf '%s\n' '#!/usr/bin/env bash' > "$path"
  printf '%s\n' "$body" >> "$path"
  chmod +x "$path"
}

WORLD1=$(new_world unconfigured)
split_triple "$WORLD1"
git -C "$R" init -q 2>/dev/null || true
stub_no_tools "$FB"
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" PATH="$FB:/usr/bin:/bin:/usr/local/bin" "$R/bin/fm-retrospective.sh" 2>&1)
expect_code 0 "$?" "unconfigured home exits 0"
assert_contains "$out" "No item carries a done/merged/reported date" "empty backlog reports plainly"
assert_contains "$out" "PR activity skipped" "no origin remote and no gh-axi: PR section skips cleanly"
assert_contains "$out" "Tracker not configured" "no youtrack token: board sections skip cleanly"
assert_contains "$out" "quota-axi not found on PATH" "no quota-axi: quota section says so plainly"
assert_contains "$out" "## Limits" "limits section always present"
pass "a home with nothing configured still produces a clean, honest report"

WORLD2=$(new_world help)
split_triple "$WORLD2"
out=$("$R/bin/fm-retrospective.sh" --help 2>&1)
expect_code 0 "$?" "--help exits 0"
assert_contains "$out" "Usage:" "help output documents usage"
assert_contains "$out" "--days" "help output documents --days"
pass "--help prints usage and exits 0"

WORLD3=$(new_world backlog-window)
split_triple "$WORLD3"
git -C "$R" init -q 2>/dev/null || true
stub_no_tools "$FB"
cat > "$H/data/backlog.md" <<'EOF'
## In flight
- [ ] still-open - work in progress (repo: x) (kind: ship) (since 2026-08-10)

## Done
- [x] recent-ship - shipped it (repo: x) (kind: ship) (since 2026-08-10) (done 2026-08-20)
- [x] recent-scout - scouted it (repo: x) (kind: scout) (done 2026-08-21)
- [x] too-old - shipped long ago (repo: x) (kind: ship) (done 2026-01-01)
EOF
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" PATH="$FB:$PATH" "$R/bin/fm-retrospective.sh" --since 2026-08-15 2>&1)
expect_code 0 "$?" "windowed report exits 0"
assert_contains "$out" "2 item(s) completed in the window" "only the two in-window Done items are counted"
assert_contains "$out" "ship: 1" "kind breakdown counts the shipped item"
assert_contains "$out" "scout: 1" "kind breakdown counts the scouted item"
assert_not_contains "$out" "too-old" "an item completed before the window is excluded"
assert_contains "$out" "1 item(s) with a recorded start date" "lead time computed only for the item carrying (since DATE)"
assert_contains "$out" "10.0d" "lead time for recent-ship is 10 days (2026-08-10 to 2026-08-20)"
assert_contains "$out" "1 completed item(s) in the window have no recorded start date" "the undated item is named as excluded, not silently dropped"
pass "window filtering, kind breakdown, and lead-time computation all read the backlog correctly"

WORLD4=$(new_world done-archive)
split_triple "$WORLD4"
git -C "$R" init -q 2>/dev/null || true
stub_no_tools "$FB"
: > "$H/data/backlog.md"
{
  printf 'Archive\n\n'
  printf '## Archived 2026-08-22\n'
  printf -- '- [x] archived-thing - old work archived by tasks-axi (repo: x) (kind: chore) (done 2026-08-19)\n'
} > "$H/data/done-archive.md"
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" PATH="$FB:$PATH" "$R/bin/fm-retrospective.sh" --since 2026-08-15 2>&1)
assert_contains "$out" "1 item(s) completed in the window" "an archived item inside the window is still counted"
assert_contains "$out" "chore: 1" "the archived item's kind is read correctly"
pass "data/done-archive.md entries are read alongside the backlog's Done section"

WORLD5=$(new_world gh-and-quota)
split_triple "$WORLD5"
git -C "$R" init -q 2>/dev/null
git -C "$R" remote add origin https://github.com/example-org/example-repo.git
write_stub "$FB/gh-axi" '
case "$*" in
  *"created:"*) echo "count: 3" ;;
  *"merged:"*) echo "count: 2" ;;
  *) echo "count: 0" ;;
esac
echo "prs: []"
'
write_stub "$FB/quota-axi" '
printf "%s\n" "{\"providers\":[{\"provider\":\"claude\",\"windows\":[{\"id\":\"seven_day\",\"label\":\"week\",\"kind\":\"weekly\",\"percentRemaining\":42,\"pace\":{\"status\":\"ahead\"}}]}]}"
'
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" PATH="$FB:$PATH" "$R/bin/fm-retrospective.sh" 2>&1)
expect_code 0 "$?" "gh-axi/quota-axi backed report exits 0"
assert_contains "$out" "example-org/example-repo: 3 opened, 2 merged" "PR counts parsed from gh-axi search output and repo resolved from origin"
assert_contains "$out" "claude week: 42% remaining, pace ahead" "quota-axi JSON is parsed into the snapshot line"
pass "gh-axi and quota-axi output is read and reported when both tools are present"

WORLD6=$(new_world board-trend)
split_triple "$WORLD6"
git -C "$R" init -q 2>/dev/null || true
stub_no_tools "$FB"
: > "$H/config/youtrack-token"
rm -f "$R/bin/fm-board-report.sh"
write_stub "$R/bin/fm-board-report.sh" '
echo "BOARD: in progress: 0, waiting on captain: 0"
echo "BOARD DIVERGENCE: local backlog item has no issue reference: a"
echo "BOARD DIVERGENCE: local backlog item has no issue reference: b"
echo "BOARD DIVERGENCE: FM-1 is In Progress on the board with no matching local task"
'
write_stub "$R/bin/fm-youtrack.sh" 'echo "[]"'
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" PATH="$FB:$PATH" "$R/bin/fm-retrospective.sh" 2>&1)
expect_code 0 "$?" "board-trend report exits 0"
assert_contains "$out" "Today: 2 local backlog item(s) with no board issue, 1 board issue(s) with no local task" "current divergence counts parsed from fm-board-report.sh output"
[ -f "$H/state/retrospective-board-trend.tsv" ] || fail "board trend history file was not written"
assert_contains "$out" "Fewer than two recorded runs" "a first run has no prior history to compare against"
out2=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" PATH="$FB:$PATH" "$R/bin/fm-retrospective.sh" 2>&1)
assert_not_contains "$out2" "Fewer than two recorded runs" "a second run the same day has two recorded points and reports a trend"
assert_contains "$out2" "flat" "unchanged divergence counts between two same-day runs report as flat"
pass "the board divergence trend is tracked across runs in a local history file, not just a snapshot"
