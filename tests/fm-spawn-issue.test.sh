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
