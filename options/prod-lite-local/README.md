# prod-lite-local

Resource-constrained, production-like local stack for Windows laptops with
roughly 4 Docker CPUs and 8-9 GB Docker memory.

## Start

Create an untracked secrets file first:

```bat
copy env\secrets.example.env options\prod-lite-local\.env
```

Populate the required local values. If `prod-full-local-http` already works on
this laptop, you can reuse those local secrets instead:

```bat
copy options\prod-full-local-http\.env options\prod-lite-local\.env
```

Then run:

```bat
scripts\doctor.bat prod-lite-local
scripts\start.bat prod-lite-local
```

The option serves the production Portal UI build through Nginx at
`http://localhost:8080`.

## Included

- Portal UI through `portal-edge` Nginx.
- PostgreSQL with AGE/pgvector bootstrap, Valkey, Kafka.
- Config Server, Discovery Server, API Gateway.
- Auth, Account, Prompt, Orchestrator, GPT, Gemini, Local AI services.
- GraphRAG retrieval service and indexing worker.
- Ollama with one small local planner model alias.

## Excluded By Default

Zipkin, Prometheus, VictoriaLogs, and Alloy are profile-gated and do not start
unless `observability` is added to `profiles.txt`.

## Local AI Policy

The default planner alias is built from `qwen2.5:1.5b-instruct` via
`infra/spike/ollama/Modelfile.planner-lite`.

Runtime constraints:

- `OLLAMA_MAX_LOADED_MODELS=1`
- `OLLAMA_NUM_PARALLEL=1`
- `OLLAMA_KEEP_ALIVE=2m`

Use a larger model only by changing option-local environment values and raising
Docker Desktop memory.

## GraphRAG Policy

GraphRAG is enabled and both retrieval and indexing containers start. Normal
usage keeps retrieval online and the indexing worker available, but bulk
ingestion should be run in small batches. Stop or unload the local model before
large indexing work on constrained laptops.
