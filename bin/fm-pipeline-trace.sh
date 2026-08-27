#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: fm-pipeline-trace.sh <meta-file> <effective-state-file> [poll-interval-seconds] [max-runtime-seconds]" >&2
  exit 2
}

[ $# -ge 2 ] || usage

CALLER_PWD=$(pwd)
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
. "bin/fm-trace-context-lib.sh"
. "bin/fm-otel-cli-lib.sh"
cd -- "$CALLER_PWD" || exit 1

META_FILE=$1
EFFECTIVE_FILE=$2
POLL_INTERVAL=${3:-5}
MAX_RUNTIME=${4:-3600}

fm_otel_cli_enabled "$EFFECTIVE_FILE" || exit 0

TRACEPARENT_VALUE=$(fm_trace_context_recorded "$META_FILE")
fm_trace_context_valid "$TRACEPARENT_VALUE" || exit 0

PHASES=(intent rebase review test document lint push pr ci)
STEP_TERMINAL='completed|failed|cancelled|skipped'
STEP_ERROR='failed|cancelled'
RUN_TERMINAL_STATUS='completed'
RUN_TERMINAL_OUTCOME='passed|failed'

declare -A phase_state=()
declare -A phase_since=()
now_epoch() { date +%s; }

steps_rows() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*steps\[[0-9]+\]\{step,status,findings,duration_ms\}:[[:space:]]*$/ { in_steps = 1; next }
    in_steps {
      if ($0 !~ /^[[:space:]]+[^,]+,[^,]+,[^,]*,[^,]*[[:space:]]*$/) { in_steps = 0; next }
      row = $0
      gsub(/[[:space:]]/, "", row)
      gsub(/"/, "", row)
      if (split(row, f, ",") >= 4) print f[1], f[2], f[4]
    }
  '
}

first_field_after_key() {
  printf '%s\n' "$1" | grep -iE "^[[:space:]]*$2:[[:space:]]*" | head -n1 |
    sed -E "s/^[[:space:]]*[A-Za-z_]+:[[:space:]]*//; s/\"//g; s/[[:space:]]*\$//" | tr '[:upper:]' '[:lower:]' || true
}

span_start_for() {
  local end=$1 duration_ms=$2 fallback=$3 seconds
  case "$duration_ms" in
    ''|*[!0-9]*) printf '%s' "$fallback"; return 0 ;;
  esac
  seconds=$(( duration_ms / 1000 ))
  [ "$seconds" -gt 0 ] || { printf '%s' "$fallback"; return 0; }
  printf '%s' "$(( end - seconds ))"
}

deadline=$(( $(now_epoch) + MAX_RUNTIME ))
run_done=0

while [ "$(now_epoch)" -lt "$deadline" ] && [ "$run_done" -eq 0 ]; do
  status_out=$(no-mistakes axi status 2>/dev/null || true)
  rows=$(steps_rows "$status_out" || true)

  for p in "${PHASES[@]}"; do
    row=$(printf '%s\n' "$rows" | awk -v phase="$p" '$1 == phase { print; exit }' || true)
    [ -n "$row" ] || continue
    state=$(printf '%s' "$row" | awk '{print $2}')
    duration_ms=$(printf '%s' "$row" | awk '{print $3}')
    printf '%s' "$state" | grep -qE '^[a-z_][a-z0-9_-]*$' || continue
    [ -n "${phase_since[$p]:-}" ] || phase_since[$p]=$(now_epoch)
    [ "$state" != "${phase_state[$p]:-}" ] || continue
    if ! printf '%s' "${phase_state[$p]:-}" | grep -qE "^($STEP_TERMINAL)\$" &&
      printf '%s' "$state" | grep -qE "^($STEP_TERMINAL)\$"; then
      span_status=ok
      printf '%s' "$state" | grep -qE "^($STEP_ERROR)\$" && span_status=error
      span_end=$(now_epoch)
      span_begin=$(span_start_for "$span_end" "$duration_ms" "${phase_since[$p]}")
      fm_otel_span "$TRACEPARENT_VALUE" firstmate-pipeline "phase:$p" "$span_begin" "$span_end" "$span_status"
    fi
    phase_state[$p]=$state
    phase_since[$p]=$(now_epoch)
  done

  run_status=$(first_field_after_key "$status_out" status)
  run_outcome=$(first_field_after_key "$status_out" outcome)
  if printf '%s' "$run_status" | grep -qE "^($RUN_TERMINAL_STATUS)\$" ||
    printf '%s' "$run_outcome" | grep -qE "^($RUN_TERMINAL_OUTCOME)\$"; then
    run_done=1
  fi

  [ "$run_done" -eq 1 ] || sleep "$POLL_INTERVAL"
done

exit 0
