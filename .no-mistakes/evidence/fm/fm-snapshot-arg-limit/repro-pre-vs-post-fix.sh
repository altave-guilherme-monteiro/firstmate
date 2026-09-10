#!/usr/bin/env bash
set -u
WT=${1:?worktree path}
PRE_FIX=7ee0c192e9d664b022361bd4609303bebfc7de14
. "$WT/tests/lib.sh"
TMP=$(fm_test_tmproot fm-e2big-repro)

make_fakebin() {
  local fb
  fb=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in list-windows) sed -n "s/^window=[^:]*://p" "${FM_HOME:?}"/state/*.meta ;; display-message) printf "codex\\n" ;; capture-pane) printf "all quiet\\n> \\n" ;; esac\nexit 0\n' > "$fb/tmux"
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

stage_pre_fix_bin() {
  local bin=$TMP/pre-fix/bin
  mkdir -p "$bin"
  ln -s "$ROOT"/bin/* "$bin/"
  rm "$bin/fm-fleet-snapshot.sh"
  git -C "$ROOT" show "$PRE_FIX:bin/fm-fleet-snapshot.sh" > "$bin/fm-fleet-snapshot.sh"
  chmod +x "$bin/fm-fleet-snapshot.sh"
  printf '%s\n' "$bin"
}

oversized_backlog_home() {
  local home=$TMP/backlog-home i=0
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  {
    printf '## In flight\n\n## Queued\n'
    while [ "$i" -lt 3000 ]; do
      printf -- '- [ ] oversized-task-%04d - Oversized filler task number %04d with extra padding text to grow every row well past the kernel single-argument limit (repo: alpha) (kind: ship)\n' "$i" "$i"
      i=$((i + 1))
    done
    printf '\n## Done\n'
  } > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

oversized_secondmate_home() {
  local home=$TMP/secondmate-home padding id i=0
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  padding=$(LC_ALL=C head -c 12000 /dev/zero | tr '\0' x)
  while [ "$i" -lt 8 ]; do
    id=$(printf 'wide-secondmate-%02d' "$i")
    mkdir -p "$home/projects/$id"
    fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "worktree=$home/projects/$id" \
      "project=alpha" "harness=codex" "kind=secondmate" "mode=secondmate" "home=$home/projects/$id"
    printf 'working: %s\n' "$padding" > "$home/state/$id.status"
    i=$((i + 1))
  done
  printf '%s\n' "$home"
}

run_case() {
  local label=$1 home=$2 bin=$3 script=$4 flag=$5 out err rc e2big schema scratch
  scratch=$TMP/scratch-$label-$(basename "$script" .sh)$flag
  mkdir -p "$scratch"
  out=$TMP/out; err=$TMP/err
  PATH="$FAKEBIN:$PATH" TMPDIR="$scratch" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$bin/$script" "$flag" > "$out" 2> "$err"; rc=$?
  e2big=$(grep -c "Argument list too long" "$err")
  schema=$(jq -r '.schema // "-"' "$out" 2>/dev/null | head -1)
  [ -n "$schema" ] || schema="(no JSON)"
  printf '| %-8s | %-26s | %-26s | %3s | %5s | %-28s | %s |\n' "$label" "$script" "$flag" "$rc" "$e2big" "$schema" \
    "$(find "$scratch" -mindepth 1 | wc -l | tr -d ' ')"
  if [ "$rc" -ne 0 ]; then sed -n '1,3p' "$err" | cut -c1-160 | sed 's/^/    stderr: /'; fi
}

FAKEBIN=$(make_fakebin "$TMP")
PRE_BIN=$(stage_pre_fix_bin)
POST_BIN=$ROOT/bin

BACKLOG_HOME=$(oversized_backlog_home)
printf 'Fixture A: %s-byte backlog.md with 3000 queued rows (MAX_ARG_STRLEN=131072)\n' "$(LC_ALL=C wc -c < "$BACKLOG_HOME/data/backlog.md" | tr -d ' ')"
printf '| build    | script                     | flag                       |  rc | E2BIG | schema                       | leftover tmp |\n'
for build in pre-fix post-fix; do
  bin=$PRE_BIN; [ "$build" = post-fix ] && bin=$POST_BIN
  run_case "$build" "$BACKLOG_HOME" "$bin" fm-fleet-snapshot.sh --json
  run_case "$build" "$BACKLOG_HOME" "$bin" fm-fleet-snapshot.sh --secondmate-home-summary
  run_case "$build" "$BACKLOG_HOME" "$bin" fm-bearings-snapshot.sh --json
done
printf 'post-fix backlog rows in snapshot: %s\n\n' \
  "$(PATH="$FAKEBIN:$PATH" FM_HOME="$BACKLOG_HOME" FM_DATA_OVERRIDE="$BACKLOG_HOME/data" "$POST_BIN/fm-fleet-snapshot.sh" --json | jq '.backlog.records | length')"

SM_HOME=$(oversized_secondmate_home)
printf 'Fixture B: 8 registered secondmates, each with a 12000-byte status line\n'
printf '| build    | script                     | flag                       |  rc | E2BIG | schema                       | leftover tmp |\n'
for build in pre-fix post-fix; do
  bin=$PRE_BIN; [ "$build" = post-fix ] && bin=$POST_BIN
  run_case "$build" "$SM_HOME" "$bin" fm-fleet-snapshot.sh --json
  run_case "$build" "$SM_HOME" "$bin" fm-bearings-snapshot.sh --json
done
printf 'post-fix secondmate_current: %s records, %s bytes\n' \
  "$(PATH="$FAKEBIN:$PATH" FM_HOME="$SM_HOME" "$POST_BIN/fm-fleet-snapshot.sh" --json | jq '.secondmate_current.records | length')" \
  "$(PATH="$FAKEBIN:$PATH" FM_HOME="$SM_HOME" "$POST_BIN/fm-fleet-snapshot.sh" --json | jq -c '.secondmate_current.records' | LC_ALL=C wc -c | tr -d ' ')"
