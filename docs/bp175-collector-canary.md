# BP1.75 Collector canary

## Scope and safety boundary

`prod-full-local-observability-collector-canary` is the opt-in local profile
for the qualified GraphRAG/Orchestrator path, the C3.2A API Gateway edge, and
the C3.2B Gemini, GPT, and Local AI provider workers. The indexing worker is
outside this path because it does not yet emit a qualified semantic trace.

The Collector is the only service connected to both private ingress and the
observability backend network. It publishes no OTLP, health, or self-metric
port to the host. Ingestion requires a bearer token supplied through the shell
or the option's untracked `.env`, never `option.env` or a committed file:

```powershell
$env:OTEL_COLLECTOR_INGEST_TOKEN = [guid]::NewGuid().ToString('N')
```

## Qualified artifact

| Item | Recorded value |
| --- | --- |
| Registry coordinate | `otel/opentelemetry-collector-contrib` |
| Release | `v0.157.0`, published 2026-07-22 |
| Pinned multi-architecture digest | `sha256:f2f01157055a9b2aab9df7118e1f1c9abf345e99b23bc7a2bc791db374a7d0f6` |
| Linux AMD64 manifest | `sha256:4eb842091c796156d4d3c994eb22ba793590f5723719dbf6b8436cb4dfc17f48` |
| Upstream revision | `145e73e8663aff5ce978ea38cf0cbd4a97017141` |
| OCI license label | `Apache-2.0` |

`scripts\check-bp175-collector-canary.ps1` validates the exact image and both
sustained and disposable proof configurations. CI runs the same validation.

## Policy registries

The Collector keeps three contracts separate:

- manually created GraphRAG and Orchestrator spans use
  `observation-envelope-v1.yaml`;
- API Gateway's standard HTTP server span uses
  `standard-sdk-http-telemetry-v1.yaml`; and
- provider-worker standard Kafka spans use
  `standard-sdk-kafka-telemetry-v1.yaml`.

For C3.2B, only `gemini-service`, `gpt-service`, and `local-ai-service`
are admitted. Each service must match its exact request `process`, reply
`send`, or request-DLQ `send` span, its Consumer or Producer kind, its
operation, and its request/reply/DLQ topic. Retained span attributes are limited
to:

- `messaging.system`;
- `messaging.operation`;
- `messaging.source.kind` and `messaging.source.name`; or
- `messaging.destination.kind` and `messaging.destination.name`.

Message keys and payloads, prompt/query/model content, client IDs, consumer
groups, offsets, partitions, peer fields, Spring listener/template identifiers,
unknown fields, events, and links are discarded or cause whole-span rejection
according to the registry. The manual and HTTP registries are not widened.

The sustained `collector-canary.yaml` has no debug exporter. It exports only
sanitized telemetry to internal Zipkin using a bounded queue and retry policy on
tmpfs. `collector-proof.yaml` adds a debug sink solely for disposable runtime
tests. Collector self-metrics remain private at `otel-collector:8888`.

## Operator proof and rollback

Run all gates before starting the option:

```powershell
pwsh -File scripts/check-bp175-collector-canary.ps1
pwsh -File scripts/bp175-collector-canary-proof.ps1
pwsh -File scripts/bp175-c32a-edge-canary-proof.ps1 -ApiGatewayImage local/llm-council/api-gateway:<tested-sha>
pwsh -File scripts/bp175-c32b-worker-canary-proof.ps1 `
  -GeminiImage local/llm-council/gemini-service:<tested-sha> `
  -GptImage local/llm-council/gpt-service:<tested-sha> `
  -LocalAiImage local/llm-council/local-ai-service:<tested-sha>
```

The C3.2B proof temporarily stops the three source worker containers and uses
clones with all external-provider credentials/endpoints blank. It submits
synthetic Kafka requests, exercises success and malformed/DLQ paths, checks
cross-thread parent continuity and privacy filtering, measures product latency,
applies bounded-backend and Collector outage pressure, verifies recovery, then
runs telemetry-disabled rollback clones. Its `finally` cleanup restores the
source workers and removes exact named proof resources.

Start the sustained opt-in profile only after passing evidence:

```bat
scripts\start.bat prod-full-local-observability-collector-canary
```

Rollback by stopping this profile and returning to
`prod-full-local-observability`. The default Java Zipkin route remains
unchanged, so no code or persistence migration is needed.

## Remaining Batch C gates

C3.2B does not authorize C3.2C default-route or production-topology cutover.
It also does not approve OpenLIT/ClickHouse intake, operator RBAC,
retention/deletion, backup/restore, resource headroom changes, indexing-worker
migration, production rollout, or later BP2/BP3 work.
