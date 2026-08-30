#!/usr/bin/env bash
set -u

. "tests/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-gate-demo)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")

hr() { printf '\n=== %s ===\n' "$1"; }

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s\n' '#!/usr/bin/env bash' > "$fakebin/tmux"
  cat >> "$fakebin/tmux" <<'SH'
set -u
case "$*" in
  *"pane_current_path"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"pane_current_command"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ -z "${FM_FAKE_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_WINDOWS"; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' '#!/usr/bin/env bash' > "$fakebin/timeout"
  printf 'shift\nexec "$@"\n' >> "$fakebin/timeout"
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

make_home() {
  local name=$1 case_dir home proj wt fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  local id
  for id in "$@"; do mkdir -p "$home/data/$id"; printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"; done
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$home/grok-home" \
    FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

show() {
  local label=$1; shift
  local home=$1 wt=$2 fakebin=$3
  shift 3
  printf '\n$ fm-spawn.sh %s\n' "$*"
  local out rc
  out=$(spawn "$home" "$wt" "$fakebin" "$@"); rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  printf '[exit %s]\n' "$rc"
}

meta_line() {
  local f=$1
  if [ -e "$f" ]; then
    printf '$ grep -E "^(kind|mode|issue|issue_waived)=" %s\n' "state/$(basename "$f")"
    grep -E '^(kind|mode|issue|issue_waived)=' "$f" || printf '(no issue= / issue_waived= line)\n'
  else
    printf '$ ls state/%s\n(no meta file written - the spawn never launched)\n' "$(basename "$f")"
  fi
}

##############################################################################
hr "R4: no tracker configured -> gate is completely inert"
IFS='|' read -r H P W F <<EOF
$(make_home no-tracker demo-untracked)
EOF
printf 'config/youtrack-token: absent\n'
show '' "$H" "$W" "$F" demo-untracked "$P" --mode no-mistakes --yolo off
meta_line "$H/state/demo-untracked.meta"

##############################################################################
hr "R2: tracker configured, SHIP spawn with no --issue/--no-issue -> REFUSED"
IFS='|' read -r H2 P2 W2 F2 <<EOF
$(make_home tracker-gate demo-gated demo-linked demo-waived)
EOF
printf 'perm:faketoken\n' > "$H2/config/youtrack-token"
printf 'config/youtrack-token: present\n'
show '' "$H2" "$W2" "$F2" demo-gated "$P2" --mode no-mistakes --yolo off
meta_line "$H2/state/demo-gated.meta"

##############################################################################
hr "R1: --issue <id> satisfies the gate and lands issue= on the task record"
show '' "$H2" "$W2" "$F2" demo-linked "$P2" --mode no-mistakes --yolo off --issue FM-1234
meta_line "$H2/state/demo-linked.meta"

##############################################################################
hr "R3: --no-issue \"<reason>\" waives the gate and records issue_waived="
show '' "$H2" "$W2" "$F2" demo-waived "$P2" --mode no-mistakes --yolo off --no-issue "firstmate-internal tooling"
meta_line "$H2/state/demo-waived.meta"

##############################################################################
hr "R3: an empty waiver reason is refused"
show '' "$H2" "$W2" "$F2" demo-empty "$P2" --mode no-mistakes --yolo off --no-issue ""

hr "R6: --issue and --no-issue are mutually exclusive"
show '' "$H2" "$W2" "$F2" demo-both "$P2" --mode no-mistakes --yolo off --issue FM-1 --no-issue "reason"

hr "hardening: a line break in the waiver reason cannot forge a second meta key"
show '' "$H2" "$W2" "$F2" demo-forge "$P2" --mode no-mistakes --yolo off --no-issue "$(printf 'internal\nkind=secondmate')"
meta_line "$H2/state/demo-forge.meta"

hr "hardening: --no-issue with no value names the flag as spelled"
show '' "$H2" "$W2" "$F2" demo-noval "$P2" --mode no-mistakes --yolo off --no-issue

##############################################################################
hr "R5: a SCOUT spawn is never gated, even with the tracker configured"
IFS='|' read -r H3 P3 W3 F3 <<EOF
$(make_home scout-ungated demo-scout)
EOF
printf 'perm:faketoken\n' > "$H3/config/youtrack-token"
show '' "$H3" "$W3" "$F3" demo-scout "$P3" --scout
meta_line "$H3/state/demo-scout.meta"

##############################################################################
hr "R5: a SECONDMATE spawn is never gated either"
SMROOT="$TMP_ROOT/secondmate"
mkdir -p "$SMROOT/home/data" "$SMROOT/home/projects" "$SMROOT/home/state" "$SMROOT/home/config" \
  "$SMROOT/sm/bin" "$SMROOT/sm/data"
SMFAKE=$(make_fakebin "$SMROOT/fake")
printf '# Firstmate\n' > "$SMROOT/sm/AGENTS.md"
printf 'demo-secondmate\n' > "$SMROOT/sm/.fm-secondmate-home"
printf 'charter\n' > "$SMROOT/sm/data/charter.md"
printf 'perm:faketoken\n' > "$SMROOT/home/config/youtrack-token"
printf '\n$ fm-spawn.sh demo-secondmate <secondmate-home> --secondmate\n'
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SMROOT/home" \
  FM_STATE_OVERRIDE="$SMROOT/home/state" FM_DATA_OVERRIDE="$SMROOT/home/data" \
  FM_PROJECTS_OVERRIDE="$SMROOT/home/projects" FM_CONFIG_OVERRIDE="$SMROOT/home/config" \
  FM_SPAWN_NO_GUARD=1 TMUX='' CLAUDECODE=1 PATH="$SMFAKE:$PATH" \
  "$SPAWN" demo-secondmate "$SMROOT/sm" --secondmate 2>&1); rc=$?
[ -z "$out" ] || printf '%s\n' "$out"
printf '[exit %s]\n' "$rc"
meta_line "$SMROOT/home/state/demo-secondmate.meta"

##############################################################################
hr "batch: one --issue on the dispatch reaches every pair"
IFS='|' read -r H4 P4 W4 F4 <<EOF
$(make_home batch demo-batch-a demo-batch-b)
EOF
printf 'perm:faketoken\n' > "$H4/config/youtrack-token"
show '' "$H4" "$W4" "$F4" "demo-batch-a=$P4" "demo-batch-b=$P4" --mode no-mistakes --yolo off --issue FM-7
meta_line "$H4/state/demo-batch-a.meta"
meta_line "$H4/state/demo-batch-b.meta"

##############################################################################
hr "R7: --relaunch refuses both override flags, and preserves the recorded linkage"
IFS='|' read -r H5 P5 W5 F5 <<EOF
$(make_home relaunch demo-relaunch demo-relaunch-waived)
EOF
printf 'perm:faketoken\n' > "$H5/config/youtrack-token"
show '' "$H5" "$W5" "$F5" demo-relaunch "$P5" --mode no-mistakes --yolo off --issue FM-77
meta_line "$H5/state/demo-relaunch.meta"
show '' "$H5" "$W5" "$F5" demo-relaunch --relaunch --issue FM-999
show '' "$H5" "$W5" "$F5" demo-relaunch --relaunch --no-issue "other"
printf '\n-- now relaunch it for real --\n'
FM_FAKE_WINDOWS="fm-demo-relaunch" show '' "$H5" "$W5" "$F5" demo-relaunch --relaunch
meta_line "$H5/state/demo-relaunch.meta"

printf '\n-- and a waived task --\n'
show '' "$H5" "$W5" "$F5" demo-relaunch-waived "$P5" --mode no-mistakes --yolo off --no-issue "personal work"
FM_FAKE_WINDOWS="fm-demo-relaunch-waived" show '' "$H5" "$W5" "$F5" demo-relaunch-waived --relaunch
meta_line "$H5/state/demo-relaunch-waived.meta"

##############################################################################
hr "downstream: the board report still sees the relaunched task as linked"
BINDIR="$TMP_ROOT/reportbin"
mkdir -p "$BINDIR"
cp "$ROOT/bin/fm-board-report.sh" "$BINDIR/"
cat > "$BINDIR/fm-youtrack.sh" <<'YT'
#!/usr/bin/env bash
[ "${1:-}" = "queries" ] || exit 0
printf 'FM-77\tShip the issue gate\tIn Progress\tCaptain\tteam-core\n'
printf 'FM-500\tSomething nobody is working on\tIn Progress\tCaptain\tteam-core\n'
YT
chmod +x "$BINDIR/fm-youtrack.sh"
printf '\n$ fm-board-report.sh   (board has FM-77 and FM-500 In Progress; local fleet holds the relaunched FM-77 task)\n'
FM_HOME="$H5" FM_CONFIG_OVERRIDE="$H5/config" FM_DATA_OVERRIDE="$H5/data" \
  FM_STATE_OVERRIDE="$H5/state" "$BINDIR/fm-board-report.sh"
printf '[exit %s]\n' "$?"
