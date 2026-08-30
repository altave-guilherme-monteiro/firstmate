#!/usr/bin/env bash
set -u

. "tests/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-issue)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s\n' '#!/usr/bin/env bash' > "$fakebin/tmux"
  cat >> "$fakebin/tmux" <<'SH'
set -u
case "$*" in
  *"pane_current_path"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' '#!/usr/bin/env bash' > "$fakebin/timeout"
  cat >> "$fakebin/timeout" <<'SH'
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/data/$id"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$case_dir/launch.log"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

ID1=issue-scout-a1
REC1=$(make_case scout-with-issue "$ID1")
IFS='|' read -r HOME1 PROJ1 WT1 FAKEBIN1 LOG1 <<EOF
$REC1
EOF
out=$(run_spawn "$HOME1" "$WT1" "$FAKEBIN1" "$LOG1" "$ID1" "$PROJ1" --scout --issue FM-42)
expect_code 0 "$?" "scout spawn with --issue succeeds"
assert_grep "issue=FM-42" "$HOME1/state/$ID1.meta" "spawn with --issue records issue= in the task meta"

ID2=issue-scout-b1
REC2=$(make_case scout-without-issue "$ID2")
IFS='|' read -r HOME2 PROJ2 WT2 FAKEBIN2 LOG2 <<EOF
$REC2
EOF
out=$(run_spawn "$HOME2" "$WT2" "$FAKEBIN2" "$LOG2" "$ID2" "$PROJ2" --scout)
expect_code 0 "$?" "scout spawn without --issue succeeds"
assert_no_grep "issue=" "$HOME2/state/$ID2.meta" "spawn without --issue never writes an issue= line"

pass "fm-spawn.sh --issue is optional and, when given, is recorded in state/<id>.meta"

mkdir -p "$TMP_ROOT/relaunch-refusal/home/state" "$TMP_ROOT/relaunch-refusal/home/data" \
  "$TMP_ROOT/relaunch-refusal/home/config" "$TMP_ROOT/relaunch-refusal/home/projects"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$TMP_ROOT/relaunch-refusal/home" \
  FM_STATE_OVERRIDE="$TMP_ROOT/relaunch-refusal/home/state" \
  FM_DATA_OVERRIDE="$TMP_ROOT/relaunch-refusal/home/data" \
  FM_PROJECTS_OVERRIDE="$TMP_ROOT/relaunch-refusal/home/projects" \
  FM_CONFIG_OVERRIDE="$TMP_ROOT/relaunch-refusal/home/config" \
  FM_SPAWN_NO_GUARD=1 \
  "$SPAWN" someid --relaunch --issue FM-1 2>&1)
expect_code 1 "$?" "--relaunch combined with --issue refuses"
assert_contains "$out" "reuses the task's recorded issue reference" \
  "the refusal names --issue as overriding the task's recorded reference"

pass "--relaunch refuses a concurrent --issue override, matching --mode/--yolo"

enable_tracker() {
  printf 'perm:faketoken\n' > "$1/config/youtrack-token"
}

run_ship_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$@" --mode no-mistakes --yolo off
}

ID3=issue-gate-a1
REC3=$(make_case gate-tracker-no-issue "$ID3")
IFS='|' read -r HOME3 PROJ3 WT3 FAKEBIN3 LOG3 <<EOF
$REC3
EOF
enable_tracker "$HOME3"
out=$(run_ship_spawn "$HOME3" "$WT3" "$FAKEBIN3" "$LOG3" "$ID3" "$PROJ3")
expect_code 1 "$?" "ship spawn without --issue/--no-issue refuses when the tracker is configured"
assert_contains "$out" "starts on the board" \
  "the refusal names that company work starts on the board"
assert_contains "$out" "--no-issue" \
  "the refusal names --no-issue as the waiver"
[ -e "$HOME3/state/$ID3.meta" ] && fail "gate refusal: no meta should be written"

pass "fm-spawn.sh refuses a ship spawn with a configured tracker and no --issue/--no-issue"

ID4=issue-gate-b1
REC4=$(make_case gate-tracker-with-issue "$ID4")
IFS='|' read -r HOME4 PROJ4 WT4 FAKEBIN4 LOG4 <<EOF
$REC4
EOF
enable_tracker "$HOME4"
out=$(run_ship_spawn "$HOME4" "$WT4" "$FAKEBIN4" "$LOG4" "$ID4" "$PROJ4" --issue FM-99)
expect_code 0 "$?" "ship spawn with --issue succeeds when the tracker is configured"
assert_grep "issue=FM-99" "$HOME4/state/$ID4.meta" "ship spawn with --issue records issue= in the task meta"

pass "fm-spawn.sh --issue satisfies the tracker gate for a ship spawn"

ID5=issue-gate-c1
REC5=$(make_case gate-tracker-waived "$ID5")
IFS='|' read -r HOME5 PROJ5 WT5 FAKEBIN5 LOG5 <<EOF
$REC5
EOF
enable_tracker "$HOME5"
out=$(run_ship_spawn "$HOME5" "$WT5" "$FAKEBIN5" "$LOG5" "$ID5" "$PROJ5" --no-issue "personal work")
expect_code 0 "$?" "ship spawn with --no-issue succeeds when the tracker is configured"
assert_grep "issue_waived=personal work" "$HOME5/state/$ID5.meta" \
  "ship spawn with --no-issue records issue_waived= in the task meta"

pass "fm-spawn.sh --no-issue waives the tracker gate for a ship spawn"

ID6=issue-gate-d1
REC6=$(make_case gate-no-tracker "$ID6")
IFS='|' read -r HOME6 PROJ6 WT6 FAKEBIN6 LOG6 <<EOF
$REC6
EOF
out=$(run_ship_spawn "$HOME6" "$WT6" "$FAKEBIN6" "$LOG6" "$ID6" "$PROJ6")
expect_code 0 "$?" "ship spawn without --issue succeeds when no tracker is configured"
assert_no_grep "issue=" "$HOME6/state/$ID6.meta" \
  "an inert gate never writes an issue= line the caller did not ask for"

pass "fm-spawn.sh's tracker gate is inert when config/youtrack-token is absent"

ID7=issue-gate-e1
REC7=$(make_case gate-no-issue-empty "$ID7")
IFS='|' read -r HOME7 PROJ7 WT7 FAKEBIN7 LOG7 <<EOF
$REC7
EOF
enable_tracker "$HOME7"
out=$(run_ship_spawn "$HOME7" "$WT7" "$FAKEBIN7" "$LOG7" "$ID7" "$PROJ7" --no-issue "")
expect_code 1 "$?" "--no-issue with an empty reason refuses"
assert_contains "$out" "requires a non-empty reason" \
  "the refusal names --no-issue's non-empty reason requirement"

pass "fm-spawn.sh --no-issue requires a non-empty reason"

ID8=issue-gate-f1
REC8=$(make_case gate-mutually-exclusive "$ID8")
IFS='|' read -r HOME8 PROJ8 WT8 FAKEBIN8 LOG8 <<EOF
$REC8
EOF
enable_tracker "$HOME8"
out=$(run_ship_spawn "$HOME8" "$WT8" "$FAKEBIN8" "$LOG8" "$ID8" "$PROJ8" --issue FM-1 --no-issue "reason")
expect_code 1 "$?" "--issue combined with --no-issue refuses"
assert_contains "$out" "mutually exclusive" \
  "the refusal names --issue and --no-issue as mutually exclusive"

pass "fm-spawn.sh refuses --issue combined with --no-issue"

ID9=issue-gate-g1
REC9=$(make_case gate-scout-ungated "$ID9")
IFS='|' read -r HOME9 PROJ9 WT9 FAKEBIN9 LOG9 <<EOF
$REC9
EOF
enable_tracker "$HOME9"
out=$(run_spawn "$HOME9" "$WT9" "$FAKEBIN9" "$LOG9" "$ID9" "$PROJ9" --scout)
expect_code 0 "$?" "scout spawn without --issue succeeds even with a configured tracker"
assert_no_grep "issue=" "$HOME9/state/$ID9.meta" \
  "a scout spawn is never gated and never records an unrequested issue= line"

pass "fm-spawn.sh's tracker gate never applies to a scout spawn"

make_secondmate_case() {
  local name=$1 id=$2 case_dir home sm fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  sm="$case_dir/sm"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  printf '%s|%s|%s\n' "$home" "$sm" "$fakebin"
}

ID10=issue-gate-h1
REC10=$(make_secondmate_case gate-secondmate-ungated "$ID10")
IFS='|' read -r HOME10 SM10 FAKEBIN10 <<EOF
$REC10
EOF
enable_tracker "$HOME10"
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME10" \
  FM_STATE_OVERRIDE="$HOME10/state" FM_DATA_OVERRIDE="$HOME10/data" \
  FM_PROJECTS_OVERRIDE="$HOME10/projects" FM_CONFIG_OVERRIDE="$HOME10/config" \
  FM_SPAWN_NO_GUARD=1 TMUX='' CLAUDECODE=1 PATH="$FAKEBIN10:$PATH" \
  "$SPAWN" "$ID10" "$SM10" --secondmate 2>&1)
assert_not_contains "$out" "linked YouTrack issue" \
  "a secondmate spawn is never gated by the tracker-issue check"

pass "fm-spawn.sh's tracker gate never applies to a secondmate spawn"
