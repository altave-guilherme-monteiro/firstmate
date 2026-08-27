# Verification: otel-cli consumer for the trace-context carrier

Evidence owner for [`../otel-cli-consumer.md`](../otel-cli-consumer.md).
Recorded 2026-08-27 on Linux 6.17.0-41-generic x86_64, bash, Docker 29.1.1, ShellCheck 0.11.0.

## Tooling installed

`otel-cli` v0.4.5 (`equinix-labs/otel-cli`, the maintained fork), linux amd64 static binary.

```
$ sha256sum otel-cli_0.4.5_linux_amd64.tar.gz
2f192fadfb2107a92ae617ca93fd7c0b532fa618a5ebc3917e641c6a9fbaeb45  otel-cli_0.4.5_linux_amd64.tar.gz
```

That matches the checksum published in the release's own `checksums.txt` for the same asset, fetched via `gh-axi release download v0.4.5 -R equinix-labs/otel-cli`.

Collector: `jaegertracing/all-in-one` (OTLP receiver on 4317/4318, UI on 16686), pulled at digest `sha256:ab6f1a1f0fb49ea08bcd19f6b84f6081d0d44b364b6de148e1798eb5816bacac`, started with:

```
$ docker run -d --name fm-otel-collector --rm -p 16686:16686 -p 4317:4317 -p 4318:4318 jaegertracing/all-in-one:latest
```

Any OTLP-compatible endpoint works; point elsewhere by exporting a different `OTEL_EXPORTER_OTLP_ENDPOINT` before enabling trace-context, per [`../otel-cli-consumer.md`](../otel-cli-consumer.md#enablement).

## otel-cli exec parents correctly from TRACEPARENT

```
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
$ export TRACEPARENT="00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"
$ otel-cli exec --service firstmate-pipeline --name "phase:test" -- echo "hello from phase"
hello from phase
$ curl -s "http://localhost:16686/api/traces?service=firstmate-pipeline&limit=5"
```

Result: one span, `traceID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`, `spanID=87a538497ea817d8`, `references=[{"refType":"CHILD_OF","traceID":"aaaa...","spanID":"bbbbbbbbbbbbbbbb"}]` - the exact 32-hex trace id and 16-hex span id from the injected carrier, confirming `otel-cli` reads `TRACEPARENT` from the environment and correctly parents a child span.

## Unit tests

```
$ bash tests/fm-otel-cli-lib.test.sh
ok - fm_otel_cli_enabled is false when the frozen trace-context decision is off
ok - fm_otel_cli_enabled is false when OTEL_EXPORTER_OTLP_ENDPOINT is unset even with trace-context on
ok - fm_otel_cli_enabled is false when otel-cli is not installed
ok - fm_otel_span degrades to a no-op and never fails when otel-cli is missing
ok - fm_otel_cli_available detects an installed otel-cli
ok - fm_otel_span never fails the caller when the configured OTLP endpoint is unreachable
ok - each pipeline phase observed in a steps table gets exactly one span by the time the poller exits
ok - a phase never present in any steps row emits no span at all
ok - a completed step's span duration comes from the row's duration_ms column
ok - a step observed completed before the run ends emits an ok span
ok - phases still non-terminal at run termination close with the run outcome's status code
ok - run termination reads the run: block's own status line, not any status: line in the blob
ok - repeated unparseable axi status output bails the poller out well before max-runtime
all fm-otel-cli-lib tests passed
```

## End-to-end: firstmate-minted parent stitched to phase spans

The exact fake `no-mistakes` used, shaped after the real `axi status` TOON grammar this repo's own fixtures record (`tests/fm-crew-state.test.sh`, `tests/fm-teardown.test.sh`):

```
$ mkdir -p /tmp/fm-e2e2/bin /tmp/fm-e2e2/state
$ printf '%s\n' $$ > /tmp/fm-e2e2/state/.lock
$ printf '%s on\n' $$ > /tmp/fm-e2e2/state/effective
$ printf 'traceparent=00-c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e-1122334455667788-01\n' > /tmp/fm-e2e2/task.meta
$ cat /tmp/fm-e2e2/bin/no-mistakes
#!/usr/bin/env bash
n=0
[ -f /tmp/fm-e2e2/counter ] && n=$(cat /tmp/fm-e2e2/counter)
printf '%s\n' "$(( n + 1 ))" > /tmp/fm-e2e2/counter
if [ "$n" -ge 2 ]; then
  printf 'run:\n  id: "01RUN"\n  status: completed\n  findings: none\noutcome: passed\n'
  exit 0
fi
printf 'run:\n  id: "01RUN"\n  status: running\n  findings: none\n'
if [ "$n" -eq 0 ]; then
  echo 'steps[9]{step,status,findings,summary}:'
  for p in intent rebase review test document lint push pr ci; do echo "  $p,running,0,\"agent under way\""; done
else
  echo 'steps[9]{step,status,findings,duration_ms}:'
  for p in intent rebase review test document lint; do echo "  $p,completed,0,3000"; done
  for p in push pr ci; do echo "  $p,running,0,0"; done
fi
```

Poll 1 is the `summary`-column header variant with every step `running`; poll 2 is the `duration_ms` variant with the first six steps `completed,0,3000` and `push`/`pr`/`ci` still `running`; poll 3 is the terminal shape - `status: completed`, `outcome: passed`, and no steps table at all.

```
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
$ PATH=/tmp/fm-e2e2/bin:$PATH bash bin/fm-pipeline-trace.sh \
    /tmp/fm-e2e2/task.meta /tmp/fm-e2e2/state/effective 2 60
$ echo $?
0
$ curl -s "http://localhost:16686/api/traces?traceID=c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e"
```

Result - all nine phase spans in one trace, every one parented directly under the firstmate-minted root span id `1122334455667788`. The six steps observed `completed` carry their row's `duration_ms` (3000ms); `push`, `pr` and `ci`, still non-terminal when the run went terminal, are closed at the final poll from wall-clock observation instead, which at a 2s poll interval is 4000ms - the two timing sources are visibly distinct:

```
trace: c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e
  span=ff52391ab1822c75 name='phase:intent'   parent=1122334455667788 dur=3000ms status=OK
  span=093a4a9abfc1f186 name='phase:rebase'   parent=1122334455667788 dur=3000ms status=OK
  span=64a61b62be2963e7 name='phase:review'   parent=1122334455667788 dur=3000ms status=OK
  span=3d82cb53cd243d23 name='phase:test'     parent=1122334455667788 dur=3000ms status=OK
  span=b2d0f207dd6c95e3 name='phase:document' parent=1122334455667788 dur=3000ms status=OK
  span=3e775deaab623844 name='phase:lint'     parent=1122334455667788 dur=3000ms status=OK
  span=125e25413741eca4 name='phase:push'     parent=1122334455667788 dur=4000ms status=OK
  span=bd6266532a045b11 name='phase:pr'       parent=1122334455667788 dur=4000ms status=OK
  span=6701c0c777786406 name='phase:ci'       parent=1122334455667788 dur=4000ms status=OK
```

A phase that never appears in any steps row gets no span at all, and repeated unparseable `axi status` output bails the poller out well before `max-runtime-seconds`; both are covered by the unit suite above.

## Tracing off is a no-op

```
$ unset OTEL_EXPORTER_OTLP_ENDPOINT
$ bin/fm-pipeline-trace.sh <task.meta> <effective-state-file-off>
$ echo $?
0
```

With the frozen trace-context decision `off` (or the endpoint unset, or `otel-cli` absent), `fm_otel_cli_enabled` returns false and `fm-pipeline-trace.sh` exits immediately without polling, sourcing no otel-cli behavior and emitting nothing - covered by the unit tests above.

## Lint

```
$ bin/fm-lint.sh bin/fm-otel-cli-lib.sh bin/fm-pipeline-trace.sh tests/fm-otel-cli-lib.test.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
```

Clean, no diagnostics.
