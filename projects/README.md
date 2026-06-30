# Compose Project Topology

The stack is split across **seven independent Compose projects** that share data
via **six external Docker networks**. Each project owns its own lifecycle
(`docker compose up/down/restart`) and can be redeployed without touching the
others — apart from the cross-project health-gating done by the orchestrator
scripts at the repo root. Project specifications and documentation are hosted in the sibling [`llm-council-docs`](../../llm-council-docs) repository.

## Projects

| Project                     | Services                                                       | Compose file                                      |
| --------------------------- | -------------------------------------------------------------- | ------------------------------------------------- |
| `llm-council-data`          | postgres, valkey                                               | [`projects/data/`](data/docker-compose.yml)                       |
| `llm-council-messaging`     | kafka (apache/kafka KRaft, no Zookeeper)                       | [`projects/messaging/`](messaging/docker-compose.yml)             |
| `llm-council-ai-runtime`    | ollama                                                         | [`projects/ai-runtime/`](ai-runtime/docker-compose.yml)           |
| `llm-council-observability` | zipkin, prometheus, victorialogs, alloy                        | [`projects/observability/`](observability/docker-compose.yml)     |
| `llm-council-platform`      | config-server, discovery-server                                | [`projects/platform/`](platform/docker-compose.yml)               |
| `llm-council-core`          | api-gateway + 7 Spring application services                    | [`projects/core/`](core/docker-compose.yml)                       |
| `llm-council-graphrag`      | graphrag-retrieval-service, graphrag-indexing-worker           | [`projects/graphrag/`](graphrag/docker-compose.yml)               |

## Networks

All six are bridge networks created up-front by the orchestrator scripts and
declared `external: true` in every project that joins them.

| Network                     | Joined by                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `llm-council-data`          | postgres, valkey, api-gateway, auth-service, account-service, orchestrator-service, prompt-service, graphrag-retrieval-service, graphrag-indexing-worker |
| `llm-council-messaging`     | kafka, orchestrator-service, gemini-service, gpt-service, local-ai-service, graphrag-indexing-worker                     |
| `llm-council-observability` | zipkin, prometheus, victorialogs, alloy, every Spring service (Zipkin HTTP traces), graphrag-retrieval-service, graphrag-indexing-worker |
| `llm-council-platform`      | config-server, discovery-server, **and** every Spring service (Spring Cloud Config + Eureka)                             |
| `llm-council-app`           | api-gateway + every Spring service (inter-service routing + `/internal/**`), prometheus (so it can scrape the 8 targets), graphrag-retrieval-service |
| `llm-council-ai-runtime`    | ollama, local-ai-service, graphrag-retrieval-service, graphrag-indexing-worker                                           |

Cross-project `depends_on` is NOT supported by Compose; the orchestrator scripts
poll each project's healthchecks with `up -d --wait` between stages.

## Semantic Options

All startup and deployment entrypoints are organized through semantic manifests
under [`options/`](../options/) and shared wrappers under [`scripts/`](../scripts/):

| Option | Command | Purpose |
| :--- | :--- | :--- |
| `dev-full-http` | `scripts\start.bat dev-full-http` | Full Docker-managed local development stack. |
| `dev-local-ai` | `scripts\start.bat dev-local-ai` | Ollama and local observability for IDE-hosted `local-ai-service`. |
| `prod-full-local-http` | `scripts\start.bat prod-full-local-http` | Production-like local HTTP stack. |
| `prod-full-local-observability` | `scripts\start.bat prod-full-local-observability` | Production-like local stack with loopback observability and log-file overlays. |
| `prod-lite-vps` | `scripts\deploy-vps.bat prod-lite-vps` | Builds and deploys the core platform stack to a remote VPS server. |
| `prod-lite-vps-hybrid` | `scripts\deploy-vps.bat prod-lite-vps-hybrid` and `scripts\laptop-local-ai.bat prod-lite-vps-hybrid` | Deploys core services to the VPS while running heavy AI workloads locally. |

Each script sets paths relative to the infrastructure repository before
executing, ensuring Compose files and Maven build contexts resolve consistently.

## Targeted operations

Each project has explicit image tags on its Spring services
(`${LLM_COUNCIL_IMAGE_REGISTRY:-local/llm-council}/<svc>:${IMAGE_TAG:-local}`)
with the `build:` context preserved. Targeted commands work per project:

```cmd
:: Build one image from source.
docker compose --env-file .env -f projects\core\docker-compose.yml ^
    -f projects\core\overlays\prod.yml build api-gateway

:: Pull pre-built images from a registry (after LLM_COUNCIL_IMAGE_REGISTRY +
:: IMAGE_TAG are set in .env).
docker compose --env-file .env -f projects\core\docker-compose.yml ^
    -f projects\core\overlays\prod.yml pull api-gateway

:: Start one service in isolation.
docker compose --env-file .env -f projects\core\docker-compose.yml ^
    -f projects\core\overlays\prod.yml up -d --wait api-gateway

:: Logs.
docker compose --env-file .env -f projects\core\docker-compose.yml ^
    -f projects\core\overlays\prod.yml logs --tail=200 -f api-gateway
```

## Validation

```cmd
projects\scripts\validate-compose.cmd
```

The PowerShell validator under [`scripts/validate-compose.ps1`](scripts/validate-compose.ps1)
asserts, per project:

- Base configs publish no ports.
- All declared networks are `external: true`.
- `core` prod publishes only `api-gateway:8080`.
- `core` prod-lite publishes only `api-gateway:8080` and gates `local-ai-service`
  behind the `laptop-local-ai` profile so the VPS does not start it.
- The VPS `postgres-external` overlay publishes Postgres `5432/tcp`; protect it
  with source-IP firewall rules.
- The VPS log-file overlays mount `${LOG_DIR_HOST}` into platform, core, and
  Graph-RAG services for centralized file logs.
- `core` https-facade publishes `api-gateway:8080` plus loopback-bound
  `api-gateway-https:8443` only when `projects/core/overlays/https-api-facade.yml`
  is explicitly layered in.
- `observability` prod publishes nothing; local-observability publishes exactly
  4 ports, all bound to loopback.
- `platform` and `core` Spring services have explicit image tags and retain
  build contexts.
- `infra/prometheus.yml` includes all 8 Spring application scrape targets plus
  the Graph-RAG Python retrieval/indexing `/metrics` endpoints.
- No JDWP in any prod chain; JDWP present on every Spring service in dev.

## Manual diff aids

```cmd
:: Inspect what would be published by a chain.
docker compose --env-file .env ^
    -f projects\observability\docker-compose.yml ^
    -f projects\observability\overlays\prod.yml ^
    -f projects\observability\overlays\local-observability.yml ^
    config --format json | jq ".services | to_entries[] | select(.value.ports) | {svc: .key, ports: .value.ports}"
```
