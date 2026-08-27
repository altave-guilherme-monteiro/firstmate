#!/usr/bin/env bash
set -u

CALLER_PWD=$(pwd)
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
. "tests/lib.sh"
. "bin/fm-trace-context-lib.sh"
. "bin/fm-otel-cli-lib.sh"
cd -- "$CALLER_PWD" || exit 1

TMP=$(fm_test_tmproot fm-otel-cli-lib) || fail "could not create test tmp root"
VALID='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'

write_lock() {
  printf '%s\n' "$$" > "$1/.lock"
}

write_effective() {
  printf '%s %s\n' "$$" "$2" > "$1/effective"
}

STATE_DIR="$TMP/state1"
mkdir -p "$STATE_DIR"
write_lock "$STATE_DIR"
write_effective "$STATE_DIR" off

unset OTEL_EXPORTER_OTLP_ENDPOINT
if fm_otel_cli_enabled "$STATE_DIR/effective"; then
  fail "fm_otel_cli_enabled must be false when trace-context is off"
fi
pass "fm_otel_cli_enabled is false when the frozen trace-context decision is off"

write_effective "$STATE_DIR" on
if fm_otel_cli_enabled "$STATE_DIR/effective"; then
  fail "fm_otel_cli_enabled must be false with no OTLP endpoint configured"
fi
pass "fm_otel_cli_enabled is false when OTEL_EXPORTER_OTLP_ENDPOINT is unset even with trace-context on"

FAKEBIN=$(fm_fakebin "$TMP")
ORIG_PATH=$PATH
export PATH="$FAKEBIN:/usr/bin:/bin"
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:1
if fm_otel_cli_enabled "$STATE_DIR/effective"; then
  fail "fm_otel_cli_enabled must be false when otel-cli is not on PATH"
fi
pass "fm_otel_cli_enabled is false when otel-cli is not installed"

RC=0
fm_otel_span "$VALID" svc name "$(date +%s)" "$(date +%s)" ok || RC=$?
[ "$RC" -eq 0 ] || fail "fm_otel_span must always return 0 when otel-cli is missing"
pass "fm_otel_span degrades to a no-op and never fails when otel-cli is missing"

RC=0
fm_otel_wrap "$VALID" svc name -- true || RC=$?
[ "$RC" -eq 0 ] || fail "fm_otel_wrap must return the wrapped command's own exit code (true)"
pass "fm_otel_wrap preserves a successful wrapped command's exit code with telemetry disabled"

RC=0
fm_otel_wrap "$VALID" svc name -- false || RC=$?
[ "$RC" -eq 1 ] || fail "fm_otel_wrap must return the wrapped command's own exit code (false)"
pass "fm_otel_wrap preserves a failing wrapped command's exit code with telemetry disabled"

fm_otel_wrap "$VALID" svc name 2>/dev/null && fail "fm_otel_wrap must reject a call missing the -- separator"
pass "fm_otel_wrap refuses a call with no -- separator before the command"

export PATH=$ORIG_PATH
if command -v otel-cli >/dev/null 2>&1; then
  fm_otel_cli_available || fail "fm_otel_cli_available must be true when otel-cli is on PATH"
  pass "fm_otel_cli_available detects an installed otel-cli"

  RC=0
  FM_OTEL_CLI_TIMEOUT=1 OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:1 \
    fm_otel_span "$VALID" svc name "$(date +%s)" "$(date +%s)" ok || RC=$?
  [ "$RC" -eq 0 ] || fail "fm_otel_span must always return 0 against an unreachable endpoint"
  pass "fm_otel_span never fails the caller when the configured OTLP endpoint is unreachable"
fi

echo "all fm-otel-cli-lib tests passed"
