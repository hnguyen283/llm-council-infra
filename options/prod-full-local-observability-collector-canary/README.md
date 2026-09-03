# prod-full-local-observability-collector-canary

Production-like local observability stack with the BP1.75 GraphRAG,
Orchestrator GraphRAG-client, C3.2A API Gateway edge, and C3.2B provider-worker
canaries.

- Admitted identities are `graphrag-retrieval-service`,
  `orchestrator-service`, `api-gateway`, `gemini-service`, `gpt-service`,
  and `local-ai-service`. The indexing worker retains its prior route.
- API Gateway emits authenticated OTLP/HTTP only through the private
  `llm-council-otel-ingest` network. Its closed policy admits only
  `http get /actuator/health`, kind `SPAN_KIND_SERVER`, and retains
  `method`, `outcome`, `status`, and fixed route-template `uri`.
- Provider workers emit authenticated OTLP/HTTP through the same private
  network. Their closed Kafka policy admits only the exact request `process`,
  reply `send`, and request-DLQ `send` spans and retains only messaging
  system, operation, and exact source/destination topic name and kind.
- Message keys and payloads, prompt/query/model content, raw URLs/query strings,
  headers, cookies, bodies, exception data, events, links, unknown services,
  unknown spans, and unknown attributes do not reach an exporter.
- Collector ingress requires `OTEL_COLLECTOR_INGEST_TOKEN`; it is never stored
  in `option.env`. Set it in the shell or the option's untracked `.env`:

```powershell
$env:OTEL_COLLECTOR_INGEST_TOKEN = [guid]::NewGuid().ToString('N')
```

- The sustained configuration exports only the sanitized internal Zipkin
  comparison route with bounded tmpfs buffering. `collector-proof.yaml` alone
  contains the disposable debug sink. OpenLIT and ClickHouse are not deployed.
- Shared Java Docker defaults remain unchanged. Removing the overlay rolls API
  Gateway and all three provider workers back without a code or persistence
  migration.

Run the static and runtime proofs before using the option:

```powershell
pwsh -File scripts/check-bp175-collector-canary.ps1
pwsh -File scripts/bp175-collector-canary-proof.ps1
pwsh -File scripts/bp175-c32a-edge-canary-proof.ps1 -ApiGatewayImage local/llm-council/api-gateway:<tested-sha>
pwsh -File scripts/bp175-c32b-worker-canary-proof.ps1 `
  -GeminiImage local/llm-council/gemini-service:<tested-sha> `
  -GptImage local/llm-council/gpt-service:<tested-sha> `
  -LocalAiImage local/llm-council/local-ai-service:<tested-sha>
```

The C3.2B proof clones the production-like provider-worker configuration with
credentials blank, generated Collector credentials, and exact named disposable
containers. It validates success and DLQ trace shapes, parent continuity,
privacy rejection, latency, backend saturation, Collector outage/recovery,
rollback behavior, and cleanup without contacting external model providers.

Start from `llm-council-infra` only after the proofs succeed:

```bat
scripts\start.bat prod-full-local-observability-collector-canary
```

C3.2B remains opt-in. Default-route cutover is C3.2C and requires a separate
approval.
