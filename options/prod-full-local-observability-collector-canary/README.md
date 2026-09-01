# prod-full-local-observability-collector-canary

Production-like local observability stack with the BP1.75 retrieval-only
Collector canary.

- Only `graphrag-retrieval-service` joins `llm-council-otel-ingest` and can
  reach `otel-collector`. The indexing worker has no telemetry route in this
  profile because it has no qualified semantic-span surface yet.
- Collector ingress requires `OTEL_COLLECTOR_INGEST_TOKEN`; it is never stored
  in `option.env`. Set it in the shell or the option's untracked `.env` before
  render/start, for example:

```powershell
$env:OTEL_COLLECTOR_INGEST_TOKEN = [guid]::NewGuid().ToString('N')
```

- The sustained Collector permits only three fixed span names and the explicit
  field registry. Unknown attributes are stripped, prohibited fields drop the
  whole record, and trusted stamps are added only afterward.
- The sustained configuration exports only the sanitized internal Zipkin
  comparison route with bounded tmpfs buffering. `collector-proof.yaml` alone
  contains the disposable debug sink used by the proof. OpenLIT and ClickHouse
  are not deployed by this option.
- Run the static and runtime proofs before treating the option as usable:

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\check-bp175-collector-canary.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\bp175-collector-canary-proof.ps1
```

The runtime proof cold-starts the Collector before Zipkin, checks authenticated
and unauthenticated ingestion, validates service/field filtering and self
metrics, exercises bounded backend outage pressure, then restarts Zipkin to
confirm recovery. It removes only its named `bp175-collector-proof` containers
and temporary files.

Start from `llm-council-infra` only after that proof succeeds:

```bat
scripts\start.bat prod-full-local-observability-collector-canary
```