#!/usr/bin/env bash
# The watcher raises one `check: decision-ttl` wake for each typed hold question
# whose TTL passed, once per reminder bucket, through the real wake queue.
# No endpoint, harness process, model call, or remote host is needed.
set -eu

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-decision-ttl)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$TMP_ROOT/data" "$TMP_ROOT/state" "$TMP_ROOT/config" "$TMP_ROOT/projects"
fm_test_tasks_toml "$TMP_ROOT/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$TMP_ROOT/data/backlog.md"
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

. "$ROOT/bin/fm-watch.sh"

cat > "$TMP_ROOT/spec.json" <<'EOF'
{"kind":"question","questions":[
{"id":"d1","text":"Merge branch X to main?","options":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}],"recommendation":"yes","class":"merge","undo_cost":"hours","blocks":["ship-x"]},
{"id":"d5","text":"Rename the helper?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"recommendation":"a","class":"none","undo_cost":"minutes","blocks":["ship-x"]},
{"id":"d4","text":"Which image do the rigs run?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"class":"none","undo_cost":"days"}
]}
EOF
FM_CAPTAIN_HOLD_NOW=2026-11-05T10:00:00Z "$ROOT/bin/fm-captain-hold.sh" hold sauron-plan \
  --spec "$TMP_ROOT/spec.json" --repo sample > /dev/null

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

tick_at() {
  local epoch=$1 iso=$2
  FM_CAPTAIN_HOLD_NOW=$iso decision_ttl_tick "$epoch"
}

test_each_due_question_is_raised_once_per_bucket() {
  tick_at 10000 2026-11-05T15:00:00Z
  [ "$DECISION_TTL_REMINDER" = "check: decision-ttl $FM_HOME sauron-plan question=d1 quadrant=1" ] \
    || fail "first tick raised: $DECISION_TTL_REMINDER"
  tick_at 10100 2026-11-05T15:00:00Z
  [ -z "$DECISION_TTL_REMINDER" ] || fail "the poll interval did not hold the second tick"
  tick_at 10400 2026-11-05T15:00:00Z
  [ "$DECISION_TTL_REMINDER" = "check: decision-ttl $FM_HOME sauron-plan question=d5 quadrant=3" ] \
    || fail "second tick raised: $DECISION_TTL_REMINDER"
  tick_at 10800 2026-11-05T15:00:00Z
  [ -z "$DECISION_TTL_REMINDER" ] || fail "an already raised question was raised again: $DECISION_TTL_REMINDER"
  [ "$(count_wakes)" = 2 ] || fail "wake queue rows: $(count_wakes)"
  pass "each due question is raised once per bucket"
}

test_a_new_bucket_raises_the_reminder_again() {
  tick_at 11200 2026-11-05T19:30:00Z
  [ "$DECISION_TTL_REMINDER" = "check: decision-ttl $FM_HOME sauron-plan question=d1 quadrant=1" ] \
    || fail "the 4 hour re-remind did not raise: $DECISION_TTL_REMINDER"
  [ "$(count_wakes)" = 3 ] || fail "wake queue rows: $(count_wakes)"
  pass "the next 4 hour bucket raises the reminder again"
}

fm_test_run \
  test_each_due_question_is_raised_once_per_bucket \
  test_a_new_bucket_raises_the_reminder_again
