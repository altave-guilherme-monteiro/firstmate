#!/usr/bin/env bash
set -u

. "tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-team-routing-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

new_world() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config"
  printf 'perm-x\n' > "$home/config/youtrack-token"
  printf '%s' "$home"
}

write_map() {
  local home=$1
  cat > "$home/config/team-routing"
}

fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s\n' '#!/usr/bin/env bash' > "$fakebin/curl"
  cat >> "$fakebin/curl" <<'SH'
set -u
url=${*: -1}
out=""
prev=""
for a in "$@"; do
  case "$prev" in -o) out=$a ;; esac
  prev=$a
done
case "$url" in
  *'/admin/projects?'*)
    printf '%s' '[{"shortName":"DEV","id":"0-66"},{"shortName":"OTHER","id":"0-1"}]' > "$out"
    ;;
  *'/customFields?'*)
    printf '%s' '[{"field":{"name":"State"},"bundle":{"id":"999"}},{"field":{"name":"Team"},"bundle":{"id":"123-167"}}]' > "$out"
    ;;
  *'/bundles/enum/123-167/values'*)
    printf '%s' '[{"name":"Team AI"},{"name":"Team Digital"},{"name":"Team DevX"}]' > "$out"
    ;;
  *)
    printf '%s' '{}' > "$out"
    ;;
esac
printf '200'
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

HOME1=$(new_world unconfigured)
out=$(FM_CONFIG_OVERRIDE="$HOME1/config" "$ROOT/bin/fm-team-routing.sh" resolve frontend 2>&1)
expect_code 1 "$?" "no config/team-routing refuses"
assert_contains "$out" "not configured" "names the mapping as not configured"

pass "an absent config/team-routing means routing is off for this home, silently and without a network call"

HOME2=$(new_world matched)
write_map "$HOME2" <<'EOF'
project=DEV
frontend=Team Digital
infrastructure=Team DevX
fallback=Team AI
fallback_assignee=guilherme.monteiro
EOF
FAKEBIN2=$(fake_curl "$HOME2")
out=$(PATH="$FAKEBIN2:$PATH" FM_CONFIG_OVERRIDE="$HOME2/config" "$ROOT/bin/fm-team-routing.sh" resolve infrastructure 2>&1)
expect_code 0 "$?" "a mapped category resolves"
assert_contains "$out" "team=Team DevX" "infrastructure resolves to the DevX team"
assert_not_contains "$out" "assignee=" "a directly mapped category never carries an assignee line"

pass "a category with a direct mapping resolves to its configured team, validated live"

HOME3=$(new_world fallback)
write_map "$HOME3" <<'EOF'
project=DEV
frontend=Team Digital
fallback=Team AI
fallback_assignee=guilherme.monteiro
EOF
FAKEBIN3=$(fake_curl "$HOME3")
out=$(PATH="$FAKEBIN3:$PATH" FM_CONFIG_OVERRIDE="$HOME3/config" "$ROOT/bin/fm-team-routing.sh" resolve robotics 2>&1)
expect_code 0 "$?" "an unmapped category falls back"
assert_contains "$out" "team=Team AI" "unmapped work falls back to the AI team"
assert_contains "$out" "assignee=guilherme.monteiro" "the fallback carries the captain's assignee"

pass "an unmapped category falls back to the AI team and assigns the captain, per the captain's ruling"

HOME4=$(new_world stale-mapping)
write_map "$HOME4" <<'EOF'
project=DEV
frontend=Team Retired
fallback=Team AI
fallback_assignee=guilherme.monteiro
EOF
FAKEBIN4=$(fake_curl "$HOME4")
out=$(PATH="$FAKEBIN4:$PATH" FM_CONFIG_OVERRIDE="$HOME4/config" "$ROOT/bin/fm-team-routing.sh" resolve frontend 2>&1)
expect_code 1 "$?" "a mapped team not on the live enum refuses"
assert_contains "$out" "not a current Team value" "names the stale mapping instead of inventing the enum value"

pass "a mapping that names a team the live tracker does not have is refused, never invented"

HOME5=$(new_world unknown-project)
write_map "$HOME5" <<'EOF'
project=NOPE
frontend=Team Digital
fallback=Team AI
fallback_assignee=guilherme.monteiro
EOF
FAKEBIN5=$(fake_curl "$HOME5")
out=$(PATH="$FAKEBIN5:$PATH" FM_CONFIG_OVERRIDE="$HOME5/config" "$ROOT/bin/fm-team-routing.sh" resolve frontend 2>&1)
expect_code 1 "$?" "a project= not present on the tracker refuses"
assert_contains "$out" "does not exist on the live tracker" "names the unresolved project"

pass "a mapping project the tracker does not have is refused with a clear diagnostic"
