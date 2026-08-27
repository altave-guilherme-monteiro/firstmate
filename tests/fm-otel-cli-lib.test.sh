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

POLLER_DIR="$TMP/poller"
mkdir -p "$POLLER_DIR/bin" "$POLLER_DIR/state"
write_lock "$POLLER_DIR/state"
write_effective "$POLLER_DIR/state" on
printf 'traceparent=%s\n' "$VALID" > "$POLLER_DIR/task.meta"

cat > "$POLLER_DIR/bin/otel-cli" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_OTEL_LOG"
FAKE
cat > "$POLLER_DIR/bin/no-mistakes" <<'FAKE'
#!/usr/bin/env bash
n=0
[ -f "$FM_FAKE_NM_COUNTER" ] && n=$(cat "$FM_FAKE_NM_COUNTER")
printf '%s\n' "$(( n + 1 ))" > "$FM_FAKE_NM_COUNTER"
echo "task: make the review outcome failed for a cancelled ci run"
echo "log: /tmp/run/review-failed.log"
echo "steps[9]{name,state}:"
if [ "$n" -eq 0 ]; then
  echo "  intent,running"
  echo "  review,pending"
else
  echo "  intent,passed"
  echo "  review,failed"
  echo "outcome: checks green"
fi
FAKE
chmod +x "$POLLER_DIR/bin/otel-cli" "$POLLER_DIR/bin/no-mistakes"

FM_FAKE_OTEL_LOG="$POLLER_DIR/otel.log"
FM_FAKE_NM_COUNTER="$POLLER_DIR/counter"
export FM_FAKE_OTEL_LOG FM_FAKE_NM_COUNTER
: > "$FM_FAKE_OTEL_LOG"

PATH="$POLLER_DIR/bin:$ORIG_PATH" OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:1 \
  bash "$ROOT/bin/fm-pipeline-trace.sh" "$POLLER_DIR/task.meta" "$POLLER_DIR/state/effective" 1 20 ||
  fail "fm-pipeline-trace.sh must exit 0 against a fake pipeline"

grep -q 'phase:intent' "$FM_FAKE_OTEL_LOG" ||
  fail "the poller must emit a span for intent once its steps row reaches a terminal state"
pass "the poller emits a phase span from the steps table row, not from free text in the status header"

grep -q -- '--status-code error' "$FM_FAKE_OTEL_LOG" ||
  fail "a failed step must emit a span with error status"
pass "a failed step's span carries an error status code"

[ "$(cat "$FM_FAKE_NM_COUNTER")" -ge 2 ] ||
  fail "free text naming a failed/cancelled phase must not end the poll loop on the first iteration"
pass "run termination follows the run-level outcome line, not any status text mentioning failure"

echo "all fm-otel-cli-lib tests passed"
