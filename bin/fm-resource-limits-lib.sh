#!/usr/bin/env bash
# bin/fm-resource-limits-lib.sh - per-home memory and CPU allowances through
# systemd user slices. Sourced by bin/backends/hc.sh, bin/fm-spawn.sh, and
# bin/fm-capacity.sh. docs/configuration.md "Resource limits" owns the
# config/resource-limits format; this header owns the mechanics.
#
# A home with config/resource-limits runs each hc terminal it starts inside a
# transient scope (`systemd-run --user --scope`) under its own slice. The slice
# name comes from the resolved home path, so the lead spawned by the main home
# and the workers that lead starts later land in the same slice:
#   fm-main_<hash>.slice        a home without .fm-secondmate-home
#   fm-lead_<id>_<hash>.slice   a lead home, <id> from .fm-secondmate-home
# The `fm-` prefix makes every home slice a child of fm.slice, which carries
# the shared total allowance (the total_* keys). systemd caps a child at its
# parent, so the allowances cascade.
#
# Functions, each taking <home> [config-dir] (default <home>/config):
#   fm_resource_limits_read     parse the file into FM_RL_<KEY>; returns 0
#                               parsed, 1 absent, 2 invalid with FM_RL_ERROR.
#   fm_resource_limits_prepare  apply the limits with `systemctl --user
#                               set-property --runtime` and prove a scope
#                               starts in the slice; returns 0 with FM_RL_SLICE
#                               ready, 1 to launch unchanged (no file, or
#                               systemd user unavailable after a warning), 2 on
#                               an invalid file after an error.
#   fm_resource_limits_usage    FM_RL_SLICE, FM_RL_CURRENT_BYTES (number or
#                               unknown), FM_RL_LIMIT_BYTES (MemoryHigh, else
#                               MemoryMax; number or none), FM_RL_FREE_BYTES
#                               (number, none, or unknown); returns as read.
#   fm_resource_limits_admit    0 admits, 75 refuses with one `deferred:` line
#                               on stderr when under
#                               FM_RESOURCE_LIMITS_MIN_FREE_BYTES is free, 2 on
#                               an invalid file. An unreadable slice admits.

FM_RESOURCE_LIMITS_TOTAL_SLICE=fm.slice
FM_RESOURCE_LIMITS_MIN_FREE_BYTES=1073741824

fm_resource_limits_size_valid() {
  case "$1" in
    infinity) return 0 ;;
    *[KMGT]) set -- "${1%?}" ;;
  esac
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

fm_resource_limits_quota_valid() {
  case "$1" in *%) set -- "${1%\%}" ;; *) return 1 ;; esac
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

fm_resource_limits_bytes() {
  case "$1" in
    infinity) printf 'infinity' ;;
    *K) printf '%s' "$(( ${1%K} * 1024 ))" ;;
    *M) printf '%s' "$(( ${1%M} * 1048576 ))" ;;
    *G) printf '%s' "$(( ${1%G} * 1073741824 ))" ;;
    *T) printf '%s' "$(( ${1%T} * 1099511627776 ))" ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_resource_limits_read() {
  local file="${2:-$1/config}/resource-limits" line key value lineno=0
  FM_RL_MEMORY_HIGH='' FM_RL_MEMORY_MAX='' FM_RL_CPU_QUOTA=''
  FM_RL_TOTAL_MEMORY_HIGH='' FM_RL_TOTAL_MEMORY_MAX='' FM_RL_TOTAL_CPU_QUOTA=''
  FM_RL_ERROR=
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d ' \t\r')
    [ -n "$line" ] || continue
    key=${line%%=*}
    value=${line#*=}
    if [ "$key" = "$line" ]; then
      FM_RL_ERROR="$file line $lineno: expected key=value"
      return 2
    fi
    case "$key" in
      memory_high|memory_max|total_memory_high|total_memory_max)
        fm_resource_limits_size_valid "$value" || { FM_RL_ERROR="$file line $lineno: $key needs bytes with an optional K, M, G, or T suffix, or infinity"; return 2; } ;;
      cpu_quota|total_cpu_quota)
        fm_resource_limits_quota_valid "$value" || { FM_RL_ERROR="$file line $lineno: $key needs a percentage such as 400%"; return 2; } ;;
      *) FM_RL_ERROR="$file line $lineno: unknown key $key"; return 2 ;;
    esac
    printf -v "FM_RL_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" '%s' "$value"
  done < "$file"
  return 0
}

fm_resource_limits_slice() {
  local root id prefix=main hash
  root=$(cd "$1" 2>/dev/null && pwd -P) || root=$1
  if [ -f "$1/.fm-secondmate-home" ]; then
    id=$(tr -- '-.' '__' < "$1/.fm-secondmate-home" | tr -cd 'A-Za-z0-9_')
    [ -z "$id" ] || prefix="lead_$id"
  fi
  hash=$(printf '%s' "$root" | cksum | awk '{printf "%08x", $1}')
  printf 'fm-%s_%s.slice' "$prefix" "$hash"
}

fm_resource_limits_set() {
  local props=()
  [ -z "$2" ] || props+=("MemoryHigh=$2")
  [ -z "$3" ] || props+=("MemoryMax=$3")
  [ -z "$4" ] || props+=("CPUQuota=$4")
  [ "${#props[@]}" -eq 0 ] || systemctl --user set-property --runtime "$1" "${props[@]}" >/dev/null 2>&1
}

fm_resource_limits_prepare() {
  local rc
  rc=0
  fm_resource_limits_read "$@" || rc=$?
  [ "$rc" -ne 1 ] || return 1
  [ "$rc" -eq 0 ] || { echo "error: $FM_RL_ERROR" >&2; return 2; }
  FM_RL_SLICE=$(fm_resource_limits_slice "$1")
  if ! command -v systemd-run >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1 \
    || ! fm_resource_limits_set "$FM_RESOURCE_LIMITS_TOTAL_SLICE" "$FM_RL_TOTAL_MEMORY_HIGH" "$FM_RL_TOTAL_MEMORY_MAX" "$FM_RL_TOTAL_CPU_QUOTA" \
    || ! fm_resource_limits_set "$FM_RL_SLICE" "$FM_RL_MEMORY_HIGH" "$FM_RL_MEMORY_MAX" "$FM_RL_CPU_QUOTA" \
    || ! systemd-run --user --scope --quiet --collect --slice="$FM_RL_SLICE" true >/dev/null 2>&1; then
    echo "warning: systemd user is not available; launching without the resource limits of $FM_RL_SLICE" >&2
    return 1
  fi
  [ "$(systemctl --user show -p MemoryMax --value "$FM_RESOURCE_LIMITS_TOTAL_SLICE" 2>/dev/null)" != infinity ] \
    || echo "warning: $FM_RESOURCE_LIMITS_TOTAL_SLICE has no MemoryMax; set total_memory_max in the main home's config/resource-limits" >&2
  return 0
}

fm_resource_limits_usage() {
  local rc limit current
  FM_RL_SLICE='' FM_RL_CURRENT_BYTES=unknown FM_RL_LIMIT_BYTES=none FM_RL_FREE_BYTES=none
  rc=0
  fm_resource_limits_read "$@" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  FM_RL_SLICE=$(fm_resource_limits_slice "$1")
  limit=${FM_RL_MEMORY_HIGH:-$FM_RL_MEMORY_MAX}
  [ -z "$limit" ] || FM_RL_LIMIT_BYTES=$(fm_resource_limits_bytes "$limit")
  [ "$FM_RL_LIMIT_BYTES" != infinity ] || FM_RL_LIMIT_BYTES=none
  current=$(systemctl --user show -p MemoryCurrent --value "$FM_RL_SLICE" 2>/dev/null) || current=unknown
  case "$current" in
    '[not set]') FM_RL_CURRENT_BYTES=0 ;;
    ''|*[!0-9]*) FM_RL_CURRENT_BYTES=unknown ;;
    *) FM_RL_CURRENT_BYTES=$current ;;
  esac
  if [ "$FM_RL_LIMIT_BYTES" != none ]; then
    FM_RL_FREE_BYTES=unknown
    [ "$FM_RL_CURRENT_BYTES" = unknown ] || FM_RL_FREE_BYTES=$((FM_RL_LIMIT_BYTES - FM_RL_CURRENT_BYTES))
  fi
  return 0
}

fm_resource_limits_admit() {
  local rc
  rc=0
  fm_resource_limits_usage "$@" || rc=$?
  [ "$rc" -ne 1 ] || return 0
  [ "$rc" -eq 0 ] || { echo "error: $FM_RL_ERROR" >&2; return 2; }
  case "$FM_RL_FREE_BYTES" in none|unknown) return 0 ;; esac
  [ "$FM_RL_FREE_BYTES" -lt "$FM_RESOURCE_LIMITS_MIN_FREE_BYTES" ] || return 0
  echo "deferred: slice $FM_RL_SLICE has $FM_RL_CURRENT_BYTES of $FM_RL_LIMIT_BYTES bytes of memory in use, under the $FM_RESOURCE_LIMITS_MIN_FREE_BYTES bytes a new agent needs" >&2
  return 75
}
