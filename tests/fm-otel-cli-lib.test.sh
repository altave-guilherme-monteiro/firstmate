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
PHASES="intent rebase review test document lint push pr ci"
n=0
[ -f "$FM_FAKE_NM_COUNTER" ] && n=$(cat "$FM_FAKE_NM_COUNTER")
printf '%s\n' "$(( n + 1 ))" > "$FM_FAKE_NM_COUNTER"
if [ "$n" -ge 2 ]; then
  echo "run:"
  echo '  id: "01RUN"'
  echo "  status: completed"
  echo "  findings: none"
  echo "outcome: failed"
  exit 0
fi
echo "gate:"
echo "  step: review"
echo "  status: completed"
echo "run:"
echo '  id: "01RUN"'
echo "  status: running"
echo "  findings: none"
if [ "$n" -eq 0 ]; then
  echo "steps[9]{step,status,findings,summary}:"
  for p in $PHASES; do echo "  $p,running,0,\"agent under way\""; done
else
  echo "steps[9]{step,status,findings,duration_ms}:"
  for p in $PHASES; do
    if [ "$p" = intent ]; then echo "  intent,completed,0,42000"; else echo "  $p,running,0,0"; fi
  done
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

for phase in intent rebase review test document lint push pr ci; do
  [ "$(grep -cF "phase:$phase " "$FM_FAKE_OTEL_LOG")" -eq 1 ] ||
    fail "every pipeline phase must get exactly one span, got $(grep -cF "phase:$phase " "$FM_FAKE_OTEL_LOG") for $phase"
done
pass "each of the nine pipeline phases gets exactly one span by the time the poller exits"

INTENT_SPAN=$(grep -F 'phase:intent ' "$FM_FAKE_OTEL_LOG" | head -n1)
INTENT_START=$(printf '%s\n' "$INTENT_SPAN" | sed -E 's/.*--start ([0-9]+).*/\1/')
INTENT_END=$(printf '%s\n' "$INTENT_SPAN" | sed -E 's/.*--end ([0-9]+).*/\1/')
[ "$(( INTENT_END - INTENT_START ))" -eq 42 ] ||
  fail "a completed step's span must span its reported duration_ms (42000ms), got $(( INTENT_END - INTENT_START ))s"
pass "a completed step's span duration comes from the row's duration_ms column"

printf '%s\n' "$INTENT_SPAN" | grep -q -- '--status-code ok' ||
  fail "a step observed completed must emit an ok span"
pass "a step observed completed before the run ends emits an ok span"

for phase in rebase review test document lint push pr ci; do
  grep -F "phase:$phase " "$FM_FAKE_OTEL_LOG" | grep -q -- '--status-code error' ||
    fail "a phase still non-terminal when the run ends failed must close with an error span ($phase)"
done
pass "phases still non-terminal at run termination close with the run outcome's status code"

[ "$(cat "$FM_FAKE_NM_COUNTER")" -ge 3 ] ||
  fail "a gate: block status must not be read as the run status and end the poll loop"
pass "run termination reads the run: block's own status line, not any status: line in the blob"

echo "all fm-otel-cli-lib tests passed"
