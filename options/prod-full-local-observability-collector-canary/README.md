# prod-full-local-observability-collector-canary

Production-like local observability stack with the BP1.75 GraphRAG,
Orchestrator GraphRAG-client, and C3.2A API Gateway edge canaries.

- `graphrag-retrieval-service`, `orchestrator-service`, and `api-gateway` are the
  only admitted workload identities. C3.2A adds only API Gateway; Gemini, GPT,
  Local AI, and the indexing worker retain their prior routes.
- API Gateway emits authenticated OTLP/HTTP only through the private
  `llm-council-otel-ingest` network. Its closed policy admits only
  `http get /actuator/health`, kind `SPAN_KIND_SERVER`, and retains `method`,
  `outcome`, `status`, and fixed route-template `uri`.
- Raw URLs/query strings, headers, cookies, bodies, exception data, Spring
  Security fields, events, links, unknown services, and unknown shapes do not
  reach an exporter.
- Collector ingress requires `OTEL_COLLECTOR_INGEST_TOKEN`; it is never stored
  in `option.env`. Set it in the shell or the option's untracked `.env`:

```powershell
$env:OTEL_COLLECTOR_INGEST_TOKEN = [guid]::NewGuid().ToString('N')
```

- The sustained configuration exports only the sanitized internal Zipkin
  comparison route with bounded tmpfs buffering. `collector-proof.yaml` alone
  contains the disposable debug sink. OpenLIT and ClickHouse are not deployed.
- The shared Java Docker default remains unchanged; this option is the only
  C3.2A route. Removing the overlay rolls API Gateway back without a code or
  persistence migration.

Run the static and runtime proofs before using the option:

```powershell
pwsh -File scripts/check-bp175-collector-canary.ps1
pwsh -File scripts/bp175-collector-canary-proof.ps1
pwsh -File scripts/bp175-c32a-edge-canary-proof.ps1 -ApiGatewayImage local/llm-council/api-gateway:<tested-sha>
```

The C3.2A proof uses a cloned production-like API Gateway configuration, safe
health requests, generated credentials, and exact named disposable containers.
It validates baseline/canary/outage/recovery/saturation/rollback behavior and
removes all proof resources.

Start from `llm-council-infra` only after the proofs succeed:

```bat
scripts\start.bat prod-full-local-observability-collector-canary
```