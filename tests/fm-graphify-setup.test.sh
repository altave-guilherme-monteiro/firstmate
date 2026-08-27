#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-graphify-setup)

make_graphify_stub() {
  local bindir=$1
  mkdir -p "$bindir"
  printf '%s\n' '#!/usr/bin/env bash' > "$bindir/graphify"
  cat >> "$bindir/graphify" <<'STUB'
case "$1" in
  update)
    mkdir -p graphify-out/cache
    : > graphify-out/.rebuild.lock
    printf '{"nodes":[]}\n' > graphify-out/graph.json
    exit "${FM_STUB_UPDATE_EXIT:-0}"
    ;;
  claude)
    [ -n "${FM_STUB_INSTALL_HANG:-}" ] && { printf '\n## graphify\n\nquery the graph first.\n' >> CLAUDE.md; touch "$FM_STUB_INSTALL_HANG"; while [ -e "$FM_STUB_INSTALL_HANG" ]; do sleep 0.05; done; exit 0; }
    mkdir -p .claude
    [ -f .claude/settings.json ] && cp .claude/settings.json .claude/settings.json.graphify-bak
    printf '{"hooks":{"PreToolUse":[]}}\n' > .claude/settings.json
    printf '\n## graphify\n\nquery the graph first.\n' >> CLAUDE.md
    exit "${FM_STUB_INSTALL_EXIT:-0}"
    ;;
esac
exit 0
STUB
  chmod +x "$bindir/graphify"
}

new_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q .
  printf 'def seed(): pass\n' > "$repo/seed.py"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.email=test@example.com -c user.name=test commit -qm init
}

run_setup() {
  local repo=$1
  shift
  PATH="$TMP_ROOT/stub-bin:$PATH" "$@" "$ROOT/bin/fm-graphify-setup.sh" "$repo" 2>&1
}

assert_worktree_clean() {
  local repo=$1 msg=$2 status
  status=$(git -C "$repo" status --short)
  [ -z "$status" ] || fail "$msg"$'\n'"--- git status --short ---"$'\n'"$status"
}

make_graphify_stub "$TMP_ROOT/stub-bin"

test_fresh_repo_leaves_no_committable_artifact() {
  local repo out
  repo="$TMP_ROOT/fresh"
  new_repo "$repo"
  commit_all "$repo"
  out=$(run_setup "$repo" env) || fail "setup failed in a fresh repo: $out"
  assert_worktree_clean "$repo" "setup left committable artifacts in a fresh repo"
  assert_present "$repo/graphify-out/graph.json" "the graph build output is missing"
  assert_present "$repo/.claude/settings.json" "the strict hook install did not run in a repo without settings.json"
  assert_absent "$repo/CLAUDE.md" "graphify's CLAUDE.md was left behind in a repo that had none"
  pass "fm-graphify-setup.sh: a fresh repo gains the graph with nothing committable left behind"
}

test_ignored_settings_json_is_still_committable_on_demand() {
  local repo
  repo="$TMP_ROOT/force-add"
  new_repo "$repo"
  commit_all "$repo"
  run_setup "$repo" env >/dev/null || fail "setup failed before the force-add check"
  git -C "$repo" add -f .claude/settings.json || fail "git add -f could not stage the ignored settings.json"
  assert_contains "$(git -C "$repo" status --short)" ".claude/settings.json" \
    "the documented 'git add -f' escape does not stage the ignored settings.json"
  pass "fm-graphify-setup.sh: the ignored settings.json stays committable with git add -f"
}

test_existing_settings_json_is_never_touched_or_hidden() {
  local repo before after out
  repo="$TMP_ROOT/existing-settings"
  new_repo "$repo"
  mkdir -p "$repo/.claude"
  printf '@AGENTS.md\n' > "$repo/CLAUDE.md"
  printf '{"permissions":{"allow":[]}}\n' > "$repo/.claude/settings.json"
  commit_all "$repo"
  before=$(cksum < "$repo/CLAUDE.md")
  out=$(run_setup "$repo" env) || fail "setup failed with an existing settings.json: $out"
  assert_worktree_clean "$repo" "setup dirtied a repo that already had .claude/settings.json"
  after=$(cksum < "$repo/CLAUDE.md")
  [ "$before" = "$after" ] || fail "CLAUDE.md was modified in a repo that already had settings.json"
  assert_grep '"permissions"' "$repo/.claude/settings.json" "the pre-existing settings.json was overwritten"
  assert_absent "$repo/.claude/settings.json.graphify-bak" "the skipped install still littered a .graphify-bak"
  printf '{"permissions":{"allow":["Bash"]}}\n' > "$repo/.claude/settings.json"
  assert_contains "$(git -C "$repo" status --short)" ".claude/settings.json" \
    "a later edit to settings.json is hidden from git status"
  pass "fm-graphify-setup.sh: an existing settings.json is left untouched and stays visible to git"
}

test_interrupted_install_still_restores_claude_md() {
  local repo before after marker pid
  repo="$TMP_ROOT/interrupted-install"
  new_repo "$repo"
  printf '@AGENTS.md\n' > "$repo/CLAUDE.md"
  commit_all "$repo"
  before=$(cksum < "$repo/CLAUDE.md")
  marker="$TMP_ROOT/install-started"
  rm -f "$marker"
  PATH="$TMP_ROOT/stub-bin:$PATH" FM_STUB_INSTALL_HANG="$marker" \
    "$ROOT/bin/fm-graphify-setup.sh" "$repo" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$marker" ] && break; sleep 0.1; done
  [ -e "$marker" ] || fail "the hanging install stub never started"
  kill -HUP "$pid"
  rm -f "$marker"
  wait "$pid" 2>/dev/null
  after=$(cksum < "$repo/CLAUDE.md")
  [ "$before" = "$after" ] || fail "CLAUDE.md was not restored after the setup was signalled mid-install"
  assert_worktree_clean "$repo" "an interrupted install left committable artifacts behind"
  pass "fm-graphify-setup.sh: a signal mid-install still restores CLAUDE.md"
}

test_failed_install_still_restores_claude_md() {
  local repo before after code
  repo="$TMP_ROOT/failed-install"
  new_repo "$repo"
  printf '@AGENTS.md\n' > "$repo/CLAUDE.md"
  commit_all "$repo"
  before=$(cksum < "$repo/CLAUDE.md")
  run_setup "$repo" env FM_STUB_INSTALL_EXIT=3 >/dev/null 2>&1
  code=$?
  expect_code 3 "$code" "a failing graphify install"
  after=$(cksum < "$repo/CLAUDE.md")
  [ "$before" = "$after" ] || fail "CLAUDE.md was not restored after a failed install"
  assert_worktree_clean "$repo" "a failed install left committable artifacts behind"
  pass "fm-graphify-setup.sh: a failed install propagates its exit code and still restores CLAUDE.md"
}

test_interrupted_build_leaves_nothing_committable() {
  local repo code
  repo="$TMP_ROOT/interrupted-build"
  new_repo "$repo"
  commit_all "$repo"
  run_setup "$repo" env FM_STUB_UPDATE_EXIT=124 >/dev/null 2>&1
  code=$?
  expect_code 124 "$code" "an interrupted graph build"
  assert_present "$repo/graphify-out/.rebuild.lock" "the interrupted build wrote nothing to check"
  assert_worktree_clean "$repo" "an interrupted build left a committable partial graphify-out/"
  pass "fm-graphify-setup.sh: an interrupted build leaves no committable partial graph"
}

test_non_git_directory_still_builds() {
  local dir out
  dir="$TMP_ROOT/plain-dir"
  mkdir -p "$dir"
  out=$(run_setup "$dir" env) || fail "setup failed outside a git worktree: $out"
  assert_present "$dir/graphify-out/graph.json" "the graph was not built outside a git worktree"
  pass "fm-graphify-setup.sh: a directory outside a git worktree still gets a graph"
}

test_partial_preexisting_ignore_files_are_extended() {
  local repo out
  repo="$TMP_ROOT/partial-ignore"
  new_repo "$repo"
  commit_all "$repo"
  mkdir -p "$repo/.claude" "$repo/graphify-out"
  printf 'settings.local.json\n' > "$repo/.claude/.gitignore"
  printf 'stale.json\n' > "$repo/graphify-out/.gitignore"
  out=$(run_setup "$repo" env) || fail "setup failed with partial pre-existing ignore files: $out"
  assert_present "$repo/.claude/settings.json" "the strict hook install did not run in a repo without settings.json"
  git -C "$repo" check-ignore -q .claude/settings.json || fail "the graphify hook artifact stayed committable"
  git -C "$repo" check-ignore -q .claude/settings.json.graphify-bak || fail "the graphify backup artifact stayed committable"
  assert_contains "$(cat "$repo/.claude/.gitignore")" "settings.local.json" \
    "the pre-existing ignore entry was clobbered"
  assert_contains "$(git -C "$repo" status --short -uall)" "?? .claude/.gitignore" \
    "the developer's own untracked .claude/.gitignore was hidden from git status"
  pass "fm-graphify-setup.sh: partial pre-existing ignore files gain the missing graphify entries"
}

test_partial_root_ignore_still_covers_every_artifact() {
  local repo out
  repo="$TMP_ROOT/partial-root-ignore"
  new_repo "$repo"
  printf '*.json\n' > "$repo/.gitignore"
  commit_all "$repo"
  out=$(run_setup "$repo" env) || fail "setup failed with a root .gitignore covering only *.json: $out"
  assert_present "$repo/graphify-out/.rebuild.lock" "the build wrote no non-json artifact to check"
  assert_worktree_clean "$repo" "graphify-out siblings stayed committable when only graph.json was pre-ignored"
  pass "fm-graphify-setup.sh: pre-ignoring only graph.json still leaves the whole graphify-out ignored"
}

test_tracked_ignore_file_that_already_covers_allows_the_hook() {
  local repo out
  repo="$TMP_ROOT/tracked-covering-ignore"
  new_repo "$repo"
  mkdir -p "$repo/.claude"
  printf 'settings.json\n' > "$repo/.claude/.gitignore"
  commit_all "$repo"
  out=$(run_setup "$repo" env) || fail "setup failed with a tracked .claude/.gitignore that already covers settings.json: $out"
  assert_present "$repo/.claude/settings.json" "the hook was skipped even though the tracked .gitignore already covers settings.json"
  assert_worktree_clean "$repo" "the hook install dirtied a repo whose tracked .gitignore already covers its artifacts"
  pass "fm-graphify-setup.sh: a tracked .gitignore that already covers settings.json still gets the hook"
}

test_tracked_ignore_file_is_never_edited() {
  local repo out
  repo="$TMP_ROOT/tracked-ignore"
  new_repo "$repo"
  mkdir -p "$repo/.claude"
  printf 'settings.local.json\n' > "$repo/.claude/.gitignore"
  commit_all "$repo"
  out=$(run_setup "$repo" env) || fail "setup failed with a tracked .claude/.gitignore: $out"
  assert_worktree_clean "$repo" "setup edited a tracked .claude/.gitignore or leaked the hook artifacts"
  assert_absent "$repo/.claude/settings.json" "the hook was installed even though settings.json could not be ignored"
  assert_contains "$out" "skipped" "the skipped hook install was not reported"
  pass "fm-graphify-setup.sh: a tracked .gitignore is left alone and the hook install is skipped"
}

test_fresh_repo_leaves_no_committable_artifact
test_partial_preexisting_ignore_files_are_extended
test_partial_root_ignore_still_covers_every_artifact
test_tracked_ignore_file_that_already_covers_allows_the_hook
test_tracked_ignore_file_is_never_edited
test_ignored_settings_json_is_still_committable_on_demand
test_existing_settings_json_is_never_touched_or_hidden
test_failed_install_still_restores_claude_md
test_interrupted_install_still_restores_claude_md
test_interrupted_build_leaves_nothing_committable
test_non_git_directory_still_builds
