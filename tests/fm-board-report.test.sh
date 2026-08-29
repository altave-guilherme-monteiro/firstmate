#!/usr/bin/env bash
set -u

. "tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-board-report-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

new_world() {
  local name=$1 w home root
  w="$TMP_ROOT/$name"
  home="$w/home"
  root="$w/root"
  mkdir -p "$home/config" "$home/data" "$home/state" "$root/bin"
  local f
  for f in "$ROOT"/bin/*.sh; do
    ln -s "$f" "$root/bin/$(basename "$f")"
  done
  rm -f "$root/bin/fm-youtrack.sh"
  printf '%s|%s\n' "$home" "$root"
}

stub_youtrack() {
  local root=$1 body=$2
  printf '%s\n' '#!/usr/bin/env bash' > "$root/bin/fm-youtrack.sh"
  {
    printf 'if [ "%s" = queries ]; then\n' "\${1:-}"
    printf '  printf %s\n' "'$body'"
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'exit 1\n'
  } >> "$root/bin/fm-youtrack.sh"
  chmod +x "$root/bin/fm-youtrack.sh"
}

stub_youtrack_failing() {
  local root=$1
  printf '%s\n' '#!/usr/bin/env bash' > "$root/bin/fm-youtrack.sh"
  {
    printf 'echo "fm-youtrack: every configured query failed to read from the tracker" >&2\n'
    printf 'exit 1\n'
  } >> "$root/bin/fm-youtrack.sh"
  chmod +x "$root/bin/fm-youtrack.sh"
}

split_pair() { IFS='|' read -r H R <<<"$1"; }

WORLD1=$(new_world unconfigured)
split_pair "$WORLD1"
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" "$R/bin/fm-board-report.sh" 2>&1)
code=$?
expect_code 0 "$code" "unconfigured board report exits 0"
[ -z "$out" ] || fail "unconfigured board report printed output: $out"
pass "no config/youtrack-token: zero output, exit 0"

WORLD2=$(new_world symlinked-token)
split_pair "$WORLD2"
: > "$H/real-token"
ln -s "$H/real-token" "$H/config/youtrack-token"
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" "$R/bin/fm-board-report.sh" 2>&1)
expect_code 0 "$?" "symlinked token board report exits 0"
[ -z "$out" ] || fail "symlinked-token board report printed output: $out"
pass "symlinked config/youtrack-token: treated the same as unconfigured"

WORLD3=$(new_world configured)
split_pair "$WORLD3"
: > "$H/config/youtrack-token"
ROWS='FM-1\tTask\tIn Progress\tPlatform\tFix thing\n'
ROWS="${ROWS}FM-2\tTask\tWaiting on Captain\tGrowth\tApprove X\n"
ROWS="${ROWS}FM-3\tTask\tOpen\tPlatform\tBacklog item\n"
stub_youtrack "$R" "$ROWS"
cat > "$H/data/backlog.md" <<'EOF'
## Queued
- has-issue - working thing (issue: FM-2)
- no-issue-here - not linked yet

## Done
- old-thing - done (issue: FM-9)
EOF
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" "$R/bin/fm-board-report.sh" 2>&1)
expect_code 0 "$?" "configured board report exits 0"
assert_contains "$out" "in progress: 1, waiting on captain: 1" "board report counts in-progress and waiting-on-captain issues"
assert_contains "$out" "BOARD in progress: FM-1" "board report names the in-progress issue"
assert_contains "$out" "BOARD waiting on captain: FM-2" "board report names the waiting-on-captain issue"
assert_contains "$out" "no-issue-here" "divergence direction a: local item with no issue reference is reported"
assert_not_contains "$out" "has-issue" "a local item carrying an issue reference is not flagged"
assert_contains "$out" "FM-1 is In Progress on the board with no matching local task" \
  "divergence direction b: an in-progress board issue absent from local records is reported"
assert_not_contains "$out" "FM-2 is In Progress" "an in-progress issue already referenced locally is not flagged"
assert_not_contains "$out" "old-thing" "a Done backlog row is never scanned for divergence"
pass "configured tracker: counts, per-bucket issue lines, and both divergence directions all report"

WORLD4=$(new_world empty-queries)
split_pair "$WORLD4"
: > "$H/config/youtrack-token"
stub_youtrack "$R" ''
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" "$R/bin/fm-board-report.sh" 2>&1)
expect_code 0 "$?" "board report with no matching issues still exits 0"
assert_contains "$out" "no query returned any issue" "board report names an empty result rather than crashing silently"
pass "configured tracker with no matching issues reports plainly instead of failing"

WORLD5B=$(new_world read-failure)
split_pair "$WORLD5B"
: > "$H/config/youtrack-token"
stub_youtrack_failing "$R"
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" "$R/bin/fm-board-report.sh" 2>&1)
expect_code 0 "$?" "board report never fails the deferred stage even on a tracker read failure"
assert_contains "$out" "could not read the tracker" \
  "a total read failure is reported distinctly from a genuinely empty backlog"
assert_not_contains "$out" "no query returned any issue" \
  "a read failure is never worded as if the backlog were simply empty"
pass "a tracker read failure is distinguished from a genuinely empty result"

WORLD6=$(new_world duplicate-across-queries)
split_pair "$WORLD6"
: > "$H/config/youtrack-token"
ROWS='DEV-825\tTask\tIn Progress\tPlatform\tShared issue\n'
ROWS="${ROWS}DEV-825\tTask\tIn Progress\tPlatform\tShared issue\n"
ROWS="${ROWS}FM-1\tTask\tIn Progress\tPlatform\tOther issue\n"
stub_youtrack "$R" "$ROWS"
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" "$R/bin/fm-board-report.sh" 2>&1)
expect_code 0 "$?" "board report with a cross-query duplicate exits 0"
assert_contains "$out" "in progress: 2" \
  "an issue matching two configured queries is counted once, not once per match"
occurrences=$(printf '%s\n' "$out" | grep -c '^BOARD in progress: DEV-825')
[ "$occurrences" -eq 1 ] || fail "DEV-825 printed $occurrences times in the in-progress list, expected exactly 1"
pass "an issue matching more than one configured query is deduplicated by issue id"

WORLD7=$(new_world long-hold-note)
split_pair "$WORLD7"
: > "$H/config/youtrack-token"
stub_youtrack "$R" 'FM-9\tTask\tOpen\tPlatform\tUnrelated\n'
cat > "$H/data/backlog.md" <<'EOF'
## Queued
- long-hold-task - Investigate the flaky retry loop (hold: captain must decide whether to bump the retry ceiling given the vendor rate limit change, or switch providers entirely, see the attached incident doc for full context and blast radius analysis and every other consideration that could possibly matter here) blocked-by: some-other-task
EOF
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" "$R/bin/fm-board-report.sh" 2>&1)
divergence_line=$(printf '%s\n' "$out" | grep '^BOARD DIVERGENCE: local backlog item has no issue reference:')
[ -n "$divergence_line" ] || fail "no divergence line printed for the long-hold-note backlog item"
assert_not_contains "$divergence_line" "hold:" "the hold note text never reaches the digest"
assert_not_contains "$divergence_line" "blocked-by:" "the blocked-by clause never reaches the digest"
line_len=${#divergence_line}
[ "$line_len" -le 120 ] || fail "divergence line is $line_len chars, expected a short single line (got: $divergence_line)"
assert_contains "$divergence_line" "long-hold-task" "the divergence line still names the task id"
pass "a backlog item with a long hold note produces one short, scannable divergence line"

WORLD5=$(new_world state-meta-reference)
split_pair "$WORLD5"
: > "$H/config/youtrack-token"
ROWS='FM-5\tTask\tIn Progress\tPlatform\tTracked via meta only\n'
stub_youtrack "$R" "$ROWS"
printf '%s\n' 'issue=FM-5' > "$H/state/task-a.meta"
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$R" "$R/bin/fm-board-report.sh" 2>&1)
expect_code 0 "$?" "board report reads state meta references"
assert_not_contains "$out" "FM-5 is In Progress" \
  "an in-progress issue referenced only by state/<id>.meta issue= is not flagged as divergent"
pass "state/<id>.meta issue= references count as a known local reference"
