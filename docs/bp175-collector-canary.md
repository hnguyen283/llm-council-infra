# BP1.75 Collector canary

## Scope and safety boundary

`prod-full-local-observability-collector-canary` is a local, retrieval-only
proof profile. `graphrag-retrieval-service` is the sole workload on the private
`llm-council-otel-ingest` network. The indexing worker is intentionally outside
this path: it does not yet emit a qualified semantic trace, so it must not be
presented as migrated.

The Collector is the only service connected to both private ingress and the
observability backend network. It publishes no OTLP, health, or self-metric
port to the host. Ingestion uses a required bearer token; supply it through the
shell or the option's untracked `.env`, never `option.env` or a committed file:

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

The exact image is configuration-validated by
`scripts\check-bp175-collector-canary.ps1`; CI runs the same exact-image
validation for both the sustained and disposable proof configurations.

## Policy registry

The sustained configuration accepts only authenticated traces with:

- service name `graphrag-retrieval-service`;
- span name `RetrievalPipeline`, `VectorSearch`, or `GraphTraversal`;
- no events; and
- the explicit span-field registry: `rag.query_length`, `rag.fallback_mode`,
  `rag.context_precision`, `rag.hit_miss_ratio`, `rag.confidence_score`,
  `rag.vector_hits_count`, and `rag.max_similarity`.

The Collector removes all other resource and span attributes. It rejects the
whole trace before that registry stage if a prohibited raw-content, tenant,
document, entity, prompt, completion, input/output, authorization, or cookie
attribute is present. Only after those checks does it add the trusted namespace,
environment, gateway, and policy stamps.

The sustained `collector-canary.yaml` contains no debug exporter. It exports
sanitized telemetry only to the internal Zipkin comparison endpoint through a
bounded queue/retry policy stored on tmpfs. `collector-proof.yaml` is separate
and adds the debug exporter only for a disposable runtime test. This prevents
ordinary canary operation from persisting diagnostic payloads in container logs.

Collector self-metrics are exposed only as `otel-collector:8888` on the private
ingress network. The proof checks accepted-span and queue metric families from
its temporary in-network client; no host port is exposed.

## Operator proof and rollback

Run the checks before starting the option:

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\check-bp175-collector-canary.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\bp175-collector-canary-proof.ps1
```

The runtime proof creates only the named local `bp175-collector-proof` Compose
project and temporary payloads. It cold-starts the Collector without Zipkin,
then checks authenticated allowlisted traffic, unauthenticated forged traffic,
prohibited fields, untrusted services, unknown attribute stripping, self-metric
availability, bounded comparison-backend outage pressure, and recovery after
Zipkin restarts. Cleanup removes that named proof project and its temporary
files.

Start the sustained opt-in profile only after a passing proof:

```bat
scripts\start.bat prod-full-local-observability-collector-canary
```

Rollback is independent of the product path: stop this profile and return to
`prod-full-local-observability`. GraphRAG export is blank outside the canary
option. Do not redirect workloads directly to Zipkin, OpenLIT, or ClickHouse.

## Remaining Batch C gates

This is a Collector-only, local proof. It does not approve OpenLIT/ClickHouse
artifact intake, operator RBAC, retention/deletion, backup/restore, resource
headroom, Java semantic rendering, the indexing worker, full workload
migration, or production rollout. OpenLIT remains rejected by the existing
high/critical vulnerability gate until a vendor-remediated image passes the
same qualification.