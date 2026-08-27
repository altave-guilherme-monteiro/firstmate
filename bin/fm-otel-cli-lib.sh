#!/usr/bin/env bash

FM_OTEL_CLI_TIMEOUT=${FM_OTEL_CLI_TIMEOUT:-3}

fm_otel_cli_available() {
  command -v otel-cli >/dev/null 2>&1
}

fm_otel_cli_enabled() {
  local effective_file=$1
  [ "$(fm_trace_context_session_effective "$effective_file")" = on ] || return 1
  [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ] || return 1
  fm_otel_cli_available
}

fm_otel_span() {
  local tp=$1 service=$2 name=$3 start=$4 end=$5 status=${6:-unset}
  [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ] || return 0
  fm_otel_cli_available || return 0
  TRACEPARENT="$tp" timeout "$FM_OTEL_CLI_TIMEOUT" otel-cli span \
    --service "$service" \
    --name "$name" \
    --start "$start" \
    --end "$end" \
    --status-code "$status" \
    >/dev/null 2>&1 || true
  return 0
}
