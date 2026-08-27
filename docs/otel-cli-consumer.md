# otel-cli consumer for the trace-context carrier

[`trace-context.md`](trace-context.md) mints and injects a W3C `traceparent` carrier but, by its own design, emits zero spans and has zero consumers.
This document covers the first consumer: `bin/fm-otel-cli-lib.sh` and `bin/fm-pipeline-trace.sh`, which turn a task's recorded carrier plus a `no-mistakes` pipeline run into real OTLP spans via the maintained [equinix-labs `otel-cli`](https://github.com/equinix-labs/otel-cli) fork.

## Scope

This is additive wrapping only.
It never changes what a pipeline phase does, and a missing or broken `otel-cli`, or an unreachable collector, degrades every call to exactly today's untraced behavior: the wrapped work still runs, and its result is unaffected.
No pipeline phase is ever failed, blocked, or slowed beyond a small bounded timeout on telemetry calls.

## Enablement

There is exactly one configuration owner: `config/trace-context` / `FM_TRACE_CONTEXT`, documented in [`configuration.md`](configuration.md#trace-context-propagation-configtrace-context--fm_trace_context).
This library adds no second flag.
Emission is enabled only when all of the following hold:

- the frozen home-session trace-context decision is `on` (`fm_trace_context_session_effective`);
- `OTEL_EXPORTER_OTLP_ENDPOINT` is set in the process environment, naming the OTLP endpoint to send spans to; and
- an `otel-cli` binary is present on `PATH`.

Any one of those being false is a silent, safe no-op: no span is emitted, and no caller is blocked or slowed waiting to find out.
A home with trace-context off behaves exactly as it does today, because none of the code in this document runs.

## What it does

`bin/fm-otel-cli-lib.sh` provides:

- `fm_otel_span <traceparent> <service> <name> <start-epoch> <end-epoch> [status-code]` - emits one span, parented under `<traceparent>`, covering `[start, end)`, via a single `otel-cli span` call bounded by `FM_OTEL_CLI_TIMEOUT` (default 3s), and always returns 0.

`bin/fm-pipeline-trace.sh <meta-file> <effective-state-file> [poll-interval-seconds] [max-runtime-seconds]` drives the `no-mistakes` pipeline phase wrapping.
It resolves the task's recorded carrier from `<meta-file>` (the same `traceparent=` line `trace-context.md` documents), exits immediately as a no-op when emission is not enabled, and otherwise polls `no-mistakes axi status` at `<poll-interval-seconds>` (default 5) for the run's per-step state across the nine pipeline steps `no-mistakes axi logs --help` enumerates: `intent, rebase, review, test, document, lint, push, pr, ci`.
On each step's first observed transition into a terminal state (`passed`, `failed`, `skipped`, `cancelled`, `checks-passed`), it emits one span named `phase:<step>` covering the interval since that step was first observed, parented directly under the task's root carrier - so every phase span is a sibling child of the same firstmate-minted identity, and an observer sees the whole run as one stitched trace.
The poller exits once the run itself reaches a terminal state, or after `<max-runtime-seconds>` (default 3600) as a safety bound against a wedged pipeline leaving the poller running forever.

### Usage

The poller is a standalone process an operator launches by hand alongside a run:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
  bin/fm-pipeline-trace.sh <task.meta> <state/.trace-context-effective> 5 3600 &
no-mistakes axi run ...
```

Manual launch is the intended delivery for this increment: `no-mistakes` exposes no hook point from which firstmate could start the poller automatically, so the poller observes the run from the outside via `axi status` and stops on its own when the run reaches a terminal outcome or the runtime cap expires.

### Timing precision

Phase span boundaries are bounded by the poll interval, not the pipeline's own internal step timestamps: `no-mistakes axi status` exposes step state, not step timing, so a phase's observed start is the poll at which its state first changed away from its prior value, and its observed end is the poll at which it was first seen terminal.
This is accurate to within one poll interval, which is an accepted tradeoff for wrapping a closed pipeline binary with zero coupling to its internals; a future increment that gets real per-step timestamps from `no-mistakes` itself could tighten this without changing the enablement contract or the span shape.

## Safety

- **Never blocks or fails a phase.** Every `otel-cli` invocation runs under `timeout`, so a hung, missing, or erroring `otel-cli`, or an unreachable collector, degrades to a swallowed failure and the wrapped work or poll loop continues unaffected.
- **`timeout` must exist.** Stock macOS ships no GNU coreutils `timeout`, so on such a host every `otel-cli` invocation fails immediately and is silently swallowed: no spans are emitted at all. That is within the degrade-silently contract, but it is the reason a macOS host sees an empty trace until `coreutils` is installed.
- **Bounded background runtime.** The poller has a hard wall-clock cap (`max-runtime-seconds`) independent of the pipeline's own state, so a wedged or misdetected run cannot leave a background process running indefinitely.
- **No new durable state.** Spans are sent directly to the configured OTLP endpoint, so nothing is written to task metadata or any other durable firstmate record beyond what `trace-context.md` already documents.
- **No second identity.** Every phase span is parented under the exact carrier `trace-context.md` mints and records, and this library never mints its own trace or span id.

## Verification

Repeatable evidence - the unit suite plus a real end-to-end capture against a live `otel-cli` and OTLP collector - lives in [`verification/otel-cli-consumer.md`](verification/otel-cli-consumer.md).
