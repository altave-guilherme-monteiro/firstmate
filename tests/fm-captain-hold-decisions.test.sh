#!/usr/bin/env bash
# Behavior tests for the typed hold spec, triage, and the commands the Herdr
# Decisions panel reads: hold --spec, adopt, list --json, due, decide, veto, and
# the release hygiene that keeps answered captain rows out of Queued.
# docs/decisions/0001-decisions-and-work-panels.md owns the design.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-hold-decisions)
TASKS_AXI_BIN=$(command -v tasks-axi || true)
T0=2026-11-05T10:00:00Z
T1=2026-11-05T10:30:00Z
T_LATE=2026-11-07T10:00:00Z

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

captain() {
  local home=$1 now=$2
  shift 2
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_CAPTAIN_HOLD_NOW="$now" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

tasks_in() {
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

write_spec() {
  local path=$1
  cat > "$path" <<'EOF'
{"kind":"question","origin":"sauron-merge","questions":[
{"id":"d1","text":"Merge branch X to main?","options":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}],"recommendation":"yes","class":"merge","undo_cost":"hours","blocks":["ship-x"]},
{"id":"d5","text":"Rename the helper?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"recommendation":"a","class":"none","undo_cost":"minutes","blocks":["ship-x"]},
{"id":"d6","text":"Which log format?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"recommendation":"b","class":"none","undo_cost":"hours"},
{"id":"d4","text":"Which image do the rigs run?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"class":"none","undo_cost":"days"}
]}
EOF
}

hold_plan() {
  local home=$1 spec="$home/spec.json"
  write_spec "$spec"
  tasks_in "$home" add ship-x "Ship X" --kind ship --repo sample >/dev/null || return 1
  captain "$home" "$T0" hold sauron-merge-plan --spec "$spec" --repo sample
}

items_of() {
  captain "$1" "$2" list --json | jq -c '.items'
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

test_hold_spec_computes_quadrants_and_stores_one_record() {
  local home out
  home=$(make_home spec)
  hold_plan "$home" >/dev/null || fail "hold --spec was refused"
  out=$(items_of "$home" "$T0")
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | "\(.question_id)=\(.quadrant)"] | join(",")')" \
    "d1=1,d5=3,d6=4,d4=2" "quadrants of the sample plan"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | "\(.question_id)=\(.group)"] | join(",")')" \
    "d1=now,d5=orchestrator_pending,d6=orchestrator_pending,d4=this_week" "groups before triage"
  pass "hold --spec computes a quadrant for each question"
}

test_hold_spec_links_blocked_tasks_to_the_hold() {
  local home
  home=$(make_home blocks)
  hold_plan "$home" >/dev/null || fail "hold --spec was refused"
  tasks_in "$home" show ship-x --full | grep -q 'sauron-merge-plan' \
    || fail "the blocked ship does not record the hold as its dependency"
  pass "hold --spec records the dependency of a blocked task"
}

test_hold_spec_refuses_topic_lists_and_unsafe_quadrants() {
  local home spec
  home=$(make_home refuse)
  spec="$home/bad.json"
  printf '%s' '{"kind":"question","questions":[{"id":"q","text":"A? B?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"class":"none","undo_cost":"hours"}]}' > "$spec"
  captain "$home" "$T0" hold bad-topic --spec "$spec" --repo sample >/dev/null 2>"$home/err" \
    && fail "a topic list was accepted"
  grep -q 'more than one question' "$home/err" || fail "the refusal does not name the topic list"
  printf '%s' '{"kind":"question","questions":[{"id":"q","text":"Delete the cache?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"recommendation":"a","class":"delete","undo_cost":"hours","quadrant_override":4,"reason":"cheap"}]}' > "$spec"
  captain "$home" "$T0" hold bad-override --spec "$spec" --repo sample >/dev/null 2>"$home/err" \
    && fail "a never-auto question reached quadrant 4"
  grep -q 'never-auto' "$home/err" || fail "the refusal does not name the never-auto class"
  tasks_in "$home" show bad-topic >/dev/null 2>&1 && fail "a refused spec created a task"
  pass "hold --spec refuses topic lists and never-auto overrides before any write"
}

test_due_lists_only_questions_past_their_ttl() {
  local home rows
  home=$(make_home due)
  hold_plan "$home" >/dev/null || fail "hold --spec was refused"
  assert_eq "$(captain "$home" "$T1" due | cut -f2 | sort | tr '\n' ,)" "d5,d6," "due rows before the 4 hour mark"
  rows=$(captain "$home" 2026-11-05T15:00:00Z due)
  assert_eq "$(printf '%s\n' "$rows" | cut -f2 | sort | tr '\n' ,)" "d1,d5,d6," "due rows after the 4 hour mark"
  assert_eq "$(printf '%s\n' "$rows" | awk -F '\t' '$2 == "d1" { print $5 }')" "1" "bucket of the first re-remind"
  assert_eq "$(captain "$home" 2026-11-09T15:00:00Z due | cut -f2 | sort | tr '\n' ,)" "d1,d4,d5,d6," "due rows after 3 days"
  pass "due lists each open question whose TTL passed"
}

test_decide_auto_applies_cheap_questions_and_refuses_never_auto() {
  local home
  home=$(make_home auto)
  hold_plan "$home" >/dev/null || fail "hold --spec was refused"
  captain "$home" "$T1" decide sauron-merge-plan d5 --auto >/dev/null || fail "quadrant 3 was not applied"
  captain "$home" "$T1" decide sauron-merge-plan d6 --auto >/dev/null || fail "quadrant 4 was not applied"
  captain "$home" "$T1" decide sauron-merge-plan d1 --auto >/dev/null 2>&1 && fail "a merge question was applied"
  captain "$home" "$T1" decide sauron-merge-plan d4 --auto >/dev/null 2>&1 && fail "a question without recommendation was applied"
  assert_eq "$(items_of "$home" "$T1" | jq -r '[.[] | "\(.question_id)=\(.group)"] | join(",")')" \
    "d1=now,d5=applied,d6=decided_for_you,d4=this_week" "groups after triage"
  assert_eq "$(items_of "$home" "$T1" | jq -r '.[] | select(.question_id == "d5") | .veto_until')" \
    "2026-11-06T10:30:00Z" "veto time"
  pass "decide --auto applies quadrant 3 and 4 and refuses never-auto classes"
}

test_user_answers_close_the_task_with_one_record() {
  local home
  home=$(make_home answers)
  hold_plan "$home" >/dev/null || fail "hold --spec was refused"
  captain "$home" "$T1" decide sauron-merge-plan d5 --auto >/dev/null
  captain "$home" "$T1" decide sauron-merge-plan d6 --auto >/dev/null
  captain "$home" "$T1" decide sauron-merge-plan d1 --option yes >/dev/null || fail "answer refused"
  assert_eq "$(tasks_in "$home" show sauron-merge-plan | sed -n 's/^  state: //p')" "queued" "state with a question open"
  captain "$home" "$T1" decide sauron-merge-plan d4 --option b --note "rigs run image B" >/dev/null || fail "last answer refused"
  assert_eq "$(tasks_in "$home" show sauron-merge-plan | sed -n 's/^  state: //p')" "done" "state after the last answer"
  tasks_in "$home" show sauron-merge-plan --full | grep -q 'd5: a (auto' || fail "record omits the automatic decision"
  assert_eq "$(items_of "$home" "$T1")" "[]" "items after closure"
  assert_eq "$(captain "$home" "$T1" list --json --decided-since 2026-11-05T00:00:00Z | jq -r '[.items[] | .question_id] | join(",")')" \
    "d5,d6" "digest after closure"
  pass "answers close the task when no question stays open and the digest keeps automatic decisions"
}

test_veto_reopens_inside_the_window_and_refuses_after_it() {
  local home out
  home=$(make_home veto)
  hold_plan "$home" >/dev/null || fail "hold --spec was refused"
  captain "$home" "$T1" decide sauron-merge-plan d5 --auto >/dev/null
  captain "$home" "$T1" veto sauron-merge-plan d5 >/dev/null || fail "veto inside the window was refused"
  out=$(items_of "$home" "$T1" | jq -c '.[] | select(.question_id == "d5")')
  assert_eq "$(printf '%s' "$out" | jq -r '"\(.status) \(.quadrant) \(.group)"')" "open 2 this_week" "reopened question"
  printf '%s' "$out" | jq -e '.override_reason | test("Vetoed")' >/dev/null || fail "the panel has no veto reason"
  captain "$home" "$T1" decide sauron-merge-plan d5 --auto >/dev/null 2>&1 && fail "a vetoed question was applied again"
  captain "$home" "$T1" veto sauron-merge-plan d6 >/dev/null 2>&1 && fail "an unapplied question was vetoed"
  pass "veto reopens an applied question as quadrant 2"
}

test_veto_of_a_closed_task_holds_a_new_task_and_steers_the_origin() {
  local home sender
  home=$(make_home veto-closed)
  sender="$home/send.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/send.log"\n' "$home" > "$sender"
  chmod +x "$sender"
  printf 'project=sample\n' > "$home/state/sauron-merge.meta"
  printf '%s' '{"kind":"question","origin":"sauron-merge","questions":[{"id":"d6","text":"Which log format?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"recommendation":"b","class":"none","undo_cost":"hours"}]}' > "$home/one.json"
  captain "$home" "$T0" hold log-format --spec "$home/one.json" --repo sample >/dev/null
  captain "$home" "$T1" decide log-format d6 --auto >/dev/null || fail "auto decision refused"
  assert_eq "$(tasks_in "$home" show log-format | sed -n 's/^  state: //p')" "done" "task closed by the last decision"
  FM_CAPTAIN_HOLD_SEND_BIN="$sender" captain "$home" "$T1" veto log-format d6 >/dev/null || fail "veto of a closed task refused"
  assert_eq "$(items_of "$home" "$T1" | jq -r '.[0] | "\(.task) \(.group)"')" "log-format-veto-d6 this_week" "new held task"
  grep -q 'sauron-merge Decision reversed' "$home/send.log" || fail "the origin worker was not steered"
  captain "$home" "$T_LATE" veto log-format d6 >/dev/null 2>&1 && fail "a second veto was accepted"
  pass "veto of a closed task holds a new quadrant 2 task and steers the origin"
}

test_veto_refuses_after_the_window_ends() {
  local home
  home=$(make_home veto-late)
  hold_plan "$home" >/dev/null || fail "hold --spec was refused"
  captain "$home" "$T1" decide sauron-merge-plan d5 --auto >/dev/null
  captain "$home" "$T_LATE" veto sauron-merge-plan d5 >/dev/null 2>"$home/err" && fail "late veto accepted"
  grep -q 'window' "$home/err" || fail "the refusal does not name the window"
  assert_eq "$(items_of "$home" "$T_LATE" | jq -r '.[] | select(.question_id == "d5") | .group')" "decided_for_you" "group after the window"
  pass "veto refuses after the window and the question moves to decided for you"
}

test_adopt_holds_a_status_line_and_closes_its_key() {
  local home
  home=$(make_home adopt)
  printf 'needs-decision [at=1] [key=dds-upgrade]: Upgrade the DDS stack on cam3?\n' > "$home/state/x35.status"
  assert_eq "$(captain "$home" "$T0" list --json | jq -r '.drift[] | select(.type == "unfiled") | .key')" "dds-upgrade" "unfiled row"
  captain "$home" "$T0" adopt "$home/state/x35.status" dds-upgrade >/dev/null || fail "adopt refused a parsable line"
  assert_eq "$(items_of "$home" "$T0" | jq -r '.[0] | "\(.task) \(.group)"')" "dds-upgrade this_week" "adopted item"
  assert_eq "$(captain "$home" "$T0" list --json | jq -r '[.drift[] | select(.type == "unfiled")] | length')" "0" "unfiled rows after adopt"
  tail -1 "$home/state/x35.status" | grep -q 'captain-held.*key=dds-upgrade' || fail "the status key was not closed"
  pass "adopt turns an open needs-decision line into a held task and closes the key"
}

test_adopt_leaves_an_unparsable_line_unfiled() {
  local home rc=0
  home=$(make_home adopt-unfiled)
  printf 'needs-decision [at=1] [key=topics]: Which DDS? Which cam3.json? Which zones?\n' > "$home/state/x35.status"
  captain "$home" "$T0" adopt "$home/state/x35.status" topics > "$home/out" || rc=$?
  assert_eq "$rc" "3" "adopt exit status for a topic list"
  grep -q '^unfiled: topics' "$home/out" || fail "adopt did not name the unfiled key"
  tasks_in "$home" show topics >/dev/null 2>&1 && fail "adopt created a task for an unparsable line"
  assert_eq "$(captain "$home" "$T0" list --json | jq -r '[.drift[] | select(.type == "unfiled")] | length')" "1" "row stays unfiled"
  pass "adopt leaves a topic list unfiled"
}

test_list_reports_answered_by_events() {
  local home
  home=$(make_home events)
  printf '%s' '{"kind":"question","origin":"span","watch_key":"low-memory-cache","questions":[{"id":"mem","text":"Free memory first?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"class":"none","undo_cost":"days"}]}' > "$home/mem.json"
  captain "$home" "$T0" hold span-memory-call --spec "$home/mem.json" --repo sample >/dev/null
  printf 'needs-decision [at=1] [key=low-memory-cache]: memory is low\nresolved [at=2] [key=low-memory-cache]: memory 5.4 GB available\n' > "$home/state/span.status"
  assert_eq "$(captain "$home" "$T0" list --json | jq -r '.drift[] | select(.type == "answered_by_events") | .task')" "span-memory-call" "answered by events row"
  pass "list reports a held call answered by events"
}

test_list_legacy_hold_without_spec_shows_in_this_week() {
  local home
  home=$(make_home legacy)
  captain "$home" "$T0" hold old-call --title "Old call" --reason "decide the old call" --repo sample >/dev/null
  assert_eq "$(items_of "$home" "$T0" | jq -r '.[0] | "\(.task) \(.group) \(.legacy)"')" "old-call this_week true" "legacy item"
  assert_eq "$(items_of "$home" "$T0" | jq -r '.[0].reason')" "decide the old call" "legacy reason is decoded"
  assert_eq "$(items_of "$home" "$T0" | jq -r '.[0].body | startswith("Captain hold set:")')" "true" "legacy body is carried"
  pass "list shows a hold without a spec as a legacy this_week item"
}

test_list_all_homes_reads_registered_leads_and_flags_stale_summaries() {
  local main lead out
  main=$(make_home main)
  lead=$(make_home lead)
  printf -- '- lead - charter (home: %s; scope: x; projects: ; added 2026-10-31)\n' "$lead" > "$main/data/secondmates.md"
  captain "$main" "$T0" hold main-call --title "Main call" --reason "main decision" --repo sample >/dev/null
  captain "$lead" "$T0" hold lead-call --title "Lead call" --reason "lead decision" --repo sample >/dev/null
  printf 'working [at=1]: x\n' > "$main/state/lead.status"
  touch -d '2026-11-01 00:00:00' "$main/state/lead.status"
  out=$(captain "$main" 2026-11-05T10:00:00Z list --json --all-homes)
  assert_eq "$(printf '%s' "$out" | jq -r '[.items[].task] | sort | join(",")')" "lead-call,main-call" "tasks of both homes"
  assert_eq "$(printf '%s' "$out" | jq -r '[.homes[].id] | join(",")')" "main,lead" "homes read"
  assert_eq "$(printf '%s' "$out" | jq -r '[.drift[] | select(.type == "stale_summary")] | length')" "1" "stale summary row"
  pass "list --all-homes reads each registered lead and flags a stale lead log"
}

test_release_of_a_captain_row_removes_it_from_queued() {
  local home
  home=$(make_home release)
  captain "$home" "$T0" hold gate-call --title "Gate call" --reason "approve the gate" --repo sample >/dev/null
  printf 'approved\n' > "$home/decision.txt"
  captain "$home" "$T1" answer gate-call --decision-file "$home/decision.txt" --release >/dev/null || fail "release refused"
  tasks_in "$home" list --state queued | grep -q 'gate-call' && fail "a released captain row stays Queued"
  captain "$home" "$T1" answer gate-call --decision-file "$home/decision.txt" --release >/dev/null || fail "release replay refused"
  tasks_in "$home" add ship-y "Ship Y" --kind ship --repo sample >/dev/null
  captain "$home" "$T1" hold ship-y --reason "approve the ship" >/dev/null
  captain "$home" "$T1" answer ship-y --decision-file "$home/decision.txt" --release >/dev/null || fail "ship release refused"
  tasks_in "$home" list --state queued | grep -q 'ship-y' || fail "a released ship row left Queued"
  pass "release closes a captain row and keeps a work row queued"
}

test_hold_spec_keeps_context_and_details_and_refuses_bad_types() {
  local home spec out
  home=$(make_home details)
  spec="$home/rich.json"
  printf '%s' '{"kind":"question","questions":[{"id":"q","text":"Merge the migration?","options":[{"id":"a","label":"Merge"},{"id":"b","label":"Wait"}],"recommendation":"a","class":"merge","undo_cost":"hours","context":"Blocks the redo.","details":{"text":["One.","Two."],"table":[["Rig","Count"],["X43","116"]],"links":[["PR 1","https://example.test/pr/1"]]}}]}' > "$spec"
  captain "$home" "$T0" hold rich-call --spec "$spec" --repo sample >/dev/null || fail "a spec with context and details was refused"
  out=$(items_of "$home" "$T0")
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].context')" "Blocks the redo." "context in list --json"
  assert_eq "$(printf '%s' "$out" | jq -c '.[0].details.table')" '[["Rig","Count"],["X43","116"]]' "details table in list --json"
  assert_eq "$(printf '%s' "$out" | jq -c '.[0].details.links')" '[["PR 1","https://example.test/pr/1"]]' "details links in list --json"
  printf '%s' '{"kind":"question","questions":[{"id":"q","text":"Merge it?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"class":"none","undo_cost":"days","context":"line one\nline two"}]}' > "$spec"
  captain "$home" "$T0" hold bad-context --spec "$spec" --repo sample >/dev/null 2>"$home/err" && fail "a multi-line context was accepted"
  grep -q 'context must be one line' "$home/err" || fail "the refusal does not name the context"
  printf '%s' '{"kind":"question","questions":[{"id":"q","text":"Merge it?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"class":"none","undo_cost":"days","details":{"table":[["a",1]]}}]}' > "$spec"
  captain "$home" "$T0" hold bad-details --spec "$spec" --repo sample >/dev/null 2>"$home/err" && fail "a non-string table cell was accepted"
  grep -q 'details must hold' "$home/err" || fail "the refusal does not name the details"
  pass "hold --spec keeps context and details and refuses wrong types"
}

test_re_hold_never_reopens_an_answered_question() {
  local home spec out before
  home=$(make_home rehold)
  spec="$home/again.json"
  hold_plan "$home" >/dev/null || fail "hold --spec was refused"
  before=$(items_of "$home" "$T0" | jq -r '.[0].hold_set')
  captain "$home" "$T1" decide sauron-merge-plan d1 --option yes >/dev/null || fail "answer was refused"
  out=$(items_of "$home" "$T1")
  assert_eq "$(printf '%s' "$out" | jq -r '[.[].question_id] | sort | join(",")')" "d4,d5,d6" "an answered question must leave list --json"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].answered_count')/$(printf '%s' "$out" | jq -r '.[0].question_count')" "1/4" "answered N of M"
  write_spec "$spec"
  captain "$home" "$T1" hold sauron-merge-plan --spec "$spec" >/dev/null 2>"$home/err" && fail "a re-hold that repeats an answered id was accepted"
  grep -q 'repeats an answered question id' "$home/err" || fail "the refusal does not name the answered id: $(cat "$home/err")"
  printf '%s' '{"kind":"question","questions":[{"id":"d4","text":"Which image do the rigs run?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"class":"none","undo_cost":"days"}]}' > "$spec"
  captain "$home" "$T_LATE" hold sauron-merge-plan --spec "$spec" >/dev/null || fail "a re-hold of an open question was refused"
  out=$(items_of "$home" "$T_LATE")
  assert_eq "$(printf '%s' "$out" | jq -r '[.[].question_id] | sort | join(",")')" "d4,d5,d6" "a re-hold of open ids must add nothing"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].hold_set')" "$before" "a re-hold must keep the age of the card"
  printf '%s' '{"kind":"question","questions":[{"id":"d9","text":"Follow-up: roll back on failure?","options":[{"id":"y","label":"Yes"},{"id":"n","label":"No"}],"recommendation":"y","class":"none","undo_cost":"minutes"}]}' > "$spec"
  captain "$home" "$T_LATE" hold sauron-merge-plan --spec "$spec" >/dev/null || fail "a follow-up question id was refused"
  out=$(items_of "$home" "$T_LATE")
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.added_at != null) | .question_id] | join(",")')" "d9" "only the new question carries added_at"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].answered_count')/$(printf '%s' "$out" | jq -r '.[0].question_count')" "1/5" "answered N of M after a follow-up"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].hold_set')" "$before" "a follow-up must keep the age of the card"
  pass "a re-hold merges new question ids, keeps answered questions closed, and refuses a repeated answered id"
}

fm_test_run \
  test_re_hold_never_reopens_an_answered_question \
  test_hold_spec_computes_quadrants_and_stores_one_record \
  test_hold_spec_links_blocked_tasks_to_the_hold \
  test_hold_spec_refuses_topic_lists_and_unsafe_quadrants \
  test_hold_spec_keeps_context_and_details_and_refuses_bad_types \
  test_due_lists_only_questions_past_their_ttl \
  test_decide_auto_applies_cheap_questions_and_refuses_never_auto \
  test_user_answers_close_the_task_with_one_record \
  test_veto_reopens_inside_the_window_and_refuses_after_it \
  test_veto_of_a_closed_task_holds_a_new_task_and_steers_the_origin \
  test_veto_refuses_after_the_window_ends \
  test_adopt_holds_a_status_line_and_closes_its_key \
  test_adopt_leaves_an_unparsable_line_unfiled \
  test_list_reports_answered_by_events \
  test_list_legacy_hold_without_spec_shows_in_this_week \
  test_list_all_homes_reads_registered_leads_and_flags_stale_summaries \
  test_release_of_a_captain_row_removes_it_from_queued
