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
TERMINAL='passed|failed|skipped|cancelled|checks-passed'
RUN_TERMINAL='outcome|done|failed|cancelled|checks-ready|checks green'

declare -A phase_state=()
declare -A phase_since=()
now_epoch() { date +%s; }

for p in "${PHASES[@]}"; do
  phase_state[$p]=unseen
  phase_since[$p]=$(now_epoch)
done

deadline=$(( $(now_epoch) + MAX_RUNTIME ))
run_done=0

while [ "$(now_epoch)" -lt "$deadline" ] && [ "$run_done" -eq 0 ]; do
  status_out=$(no-mistakes axi status 2>/dev/null || true)

  for p in "${PHASES[@]}"; do
    line=$(printf '%s\n' "$status_out" | grep -iE "(^|[^a-z])$p([^a-z]|\$)" | head -n1 || true)
    [ -n "$line" ] || continue
    state=$(printf '%s' "$line" | grep -ioE "$TERMINAL|running|pending|queued|blocked" | head -n1 | tr '[:upper:]' '[:lower:]' || true)
    [ -n "$state" ] || continue
    if [ "$state" != "${phase_state[$p]}" ]; then
      if printf '%s' "${phase_state[$p]}" | grep -qE "^($TERMINAL)\$"; then
        :
      elif printf '%s' "$state" | grep -qE "^($TERMINAL)\$"; then
        span_status=ok
        printf '%s' "$state" | grep -qE '^(failed|cancelled)$' && span_status=error
        fm_otel_span "$TRACEPARENT_VALUE" firstmate-pipeline "phase:$p" "${phase_since[$p]}" "$(now_epoch)" "$span_status"
      fi
      phase_state[$p]=$state
      phase_since[$p]=$(now_epoch)
    fi
  done

  if printf '%s' "$status_out" | grep -qiE "$RUN_TERMINAL"; then
    run_done=1
  fi

  [ "$run_done" -eq 1 ] || sleep "$POLL_INTERVAL"
done

exit 0
