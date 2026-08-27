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
ok - the poller emits a phase span from the steps table row, not from free text in the status header
ok - a failed step's span carries an error status code
ok - run termination follows the run-level outcome line, not any status text mentioning failure
all fm-otel-cli-lib tests passed
```

## End-to-end: firstmate-minted parent stitched to phase spans

A fake `no-mistakes` binary on `PATH` emits the real `axi status` TOON shape (`steps[9]{name,state}:` plus the nine step names `no-mistakes axi logs --help` enumerates) across three polls: `intent` running, then `intent` passed / `rebase` running, then all nine steps passed with `outcome: checks green`.
A task meta file records a firstmate-minted carrier exactly as `trace-context.md` specifies (`traceparent=00-e1b3f2a9c7d64e58a1f0b2c3d4e5f6a7-1122334455667788-01`).

```
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
$ bin/fm-pipeline-trace.sh <task.meta> <effective-state-file> 1 30
$ curl -s "http://localhost:16686/api/traces?traceID=e1b3f2a9c7d64e58a1f0b2c3d4e5f6a7"
```

Result - all nine phase spans in one trace, every one parented directly under the firstmate-minted root span id `1122334455667788`:

```
trace: e1b3f2a9c7d64e58a1f0b2c3d4e5f6a7
  span=cfdd21b5768cb0c6 name='phase:review'   parent=['1122334455667788']
  span=3052a59643354380 name='phase:test'     parent=['1122334455667788']
  span=2910a759270bfff5 name='phase:document' parent=['1122334455667788']
  span=f14238dfb175fd92 name='phase:lint'     parent=['1122334455667788']
  span=eb0f298016df56ea name='phase:pr'       parent=['1122334455667788']
  span=9ee0f55ab27f335c name='phase:intent'   parent=['1122334455667788']
  span=78446c73e961782d name='phase:rebase'   parent=['1122334455667788']
  span=71feb87e9aec3629 name='phase:push'     parent=['1122334455667788']
  span=f75445f4c81d1233 name='phase:ci'       parent=['1122334455667788']
```

This is a fake `no-mistakes` binary shaped after the real `axi status` TOON grammar and the real nine-step enum, not a live pipeline run, because standing up a full real pipeline run against a shared daemon purely to observe its output format was out of scope for this pass.
The parser in `bin/fm-pipeline-trace.sh` reads only the `name,state` rows under the `steps[N]{name,state}:` header and treats the run as finished only when a run-level `outcome:`/`status:` line carries a terminal value, so free text elsewhere in the status output cannot invent a phase span or end the poll early; minor TOON formatting drift degrades to fewer or no phase spans rather than a parse failure, per the safety contract in [`../otel-cli-consumer.md`](../otel-cli-consumer.md#safety).
This branch's own `no-mistakes` validation run is the first real pipeline run this wrapper will observe; if the live TOON shape needs a parser adjustment, that is a same-task correction to keep already-accepted behavior working, not a new requirement.

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
