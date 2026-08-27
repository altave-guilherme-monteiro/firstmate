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
ok - each of the nine pipeline phases gets exactly one span by the time the poller exits
ok - a completed step's span duration comes from the row's duration_ms column
ok - a step observed completed before the run ends emits an ok span
ok - phases still non-terminal at run termination close with the run outcome's status code
ok - run termination reads the run: block's own status line, not any status: line in the blob
all fm-otel-cli-lib tests passed
```

## End-to-end: firstmate-minted parent stitched to phase spans

A fake `no-mistakes` binary on `PATH` emits the real `axi status` TOON shapes this repo's own verified fixtures record, across three polls. Poll 1: `run:` with `status: running` and a `steps[9]{step,status,findings,summary}:` table whose rows carry a quoted summary (`intent,running,0,"agent under way"`, the `tests/fm-teardown.test.sh` variant). Poll 2: the `steps[9]{step,status,findings,duration_ms}:` variant (`tests/fm-crew-state.test.sh`) with the first six steps `completed,0,3000` and `push`/`pr`/`ci` still `running`. Poll 3: the terminal shape, `status: completed` plus `outcome: passed` and no steps table at all.
A task meta file records a firstmate-minted carrier exactly as `trace-context.md` specifies (`traceparent=00-e1b3f2a9c7d64e58a1f0b2c3d4e5f6a7-1122334455667788-01`).

```
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
$ bin/fm-pipeline-trace.sh <task.meta> <effective-state-file> 1 30
$ curl -s "http://localhost:16686/api/traces?traceID=e1b3f2a9c7d64e58a1f0b2c3d4e5f6a7"
```

Result - all nine phase spans in one trace, every one parented directly under the firstmate-minted root span id `1122334455667788`. The first six come from their rows' `duration_ms`; `push`, `pr` and `ci`, still non-terminal when the run went terminal, are closed at the final poll with the run outcome's status code:

```
trace: e1b3f2a9c7d64e58a1f0b2c3d4e5f6a7
  span=8ff85b8ced08c948 name='phase:intent'   parent=['1122334455667788'] dur=3000ms status=['OK']
  span=b032d3b3ced275dc name='phase:rebase'   parent=['1122334455667788'] dur=3000ms status=['OK']
  span=6e3cd54b5180aafc name='phase:review'   parent=['1122334455667788'] dur=3000ms status=['OK']
  span=de906db09c50776e name='phase:test'     parent=['1122334455667788'] dur=3000ms status=['OK']
  span=961d8a63b98014bc name='phase:document' parent=['1122334455667788'] dur=3000ms status=['OK']
  span=13b8e1939740078d name='phase:lint'     parent=['1122334455667788'] dur=3000ms status=['OK']
  span=1b1c531e0616a5fd name='phase:push'     parent=['1122334455667788'] dur=3000ms status=['OK']
  span=170ca7e2b42297ed name='phase:pr'       parent=['1122334455667788'] dur=3000ms status=['OK']
  span=34a59bbc956b2e46 name='phase:ci'       parent=['1122334455667788'] dur=3000ms status=['OK']
```

The fake's grammar is taken from this repo's fixtures for the real binary's output (`tests/fm-crew-state.test.sh`, `bin/fm-crew-state.sh`), so the parser under test is the one the real CLI feeds; this branch's own `no-mistakes` validation run is the first live run it observes.

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
