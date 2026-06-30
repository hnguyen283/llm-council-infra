# LLM Council - Infrastructure & Orchestration

This repository hosts infrastructure scripts, Docker Compose files, overlays, and deployment tools for the **LLM Council** platform. The core application services and business logic reside in the sibling [`llm-council`](../llm-council) repository.

---

## Architecture Topology

The infrastructure is structured into seven Compose project areas inside `projects/` that communicate over six external Docker networks:

| Project | Services | Compose File |
| :--- | :--- | :--- |
| `llm-council-data` | `postgres`, `valkey` | [`projects/data/docker-compose.yml`](projects/data/docker-compose.yml) |
| `llm-council-messaging` | `kafka` (Apache KRaft) | [`projects/messaging/docker-compose.yml`](projects/messaging/docker-compose.yml) |
| `llm-council-ai-runtime` | `ollama` | [`projects/ai-runtime/docker-compose.yml`](projects/ai-runtime/docker-compose.yml) |
| `llm-council-observability` | `zipkin`, `prometheus`, `victorialogs`, `alloy` | [`projects/observability/docker-compose.yml`](projects/observability/docker-compose.yml) |
| `llm-council-platform` | `config-server`, `discovery-server` | [`projects/platform/docker-compose.yml`](projects/platform/docker-compose.yml) |
| `llm-council-core` | `api-gateway` + application services | [`projects/core/docker-compose.yml`](projects/core/docker-compose.yml) |
| `llm-council-graphrag` | `graphrag-retrieval-service`, `graphrag-indexing-worker` | [`projects/graphrag/docker-compose.yml`](projects/graphrag/docker-compose.yml) |

---

## Sibling Repository Convention

> [!IMPORTANT]
> **Build Context Dependency**
> Every application service in the Compose files uses relative paths targeting the sibling [`llm-council`](../llm-council) directory. Both repositories must reside in the same parent directory, for example `D:\Project\LLMCouncil\`.

---

## Database Isolation Architecture

To safeguard knowledge graph data and optimize costs, the database layer is split between local and VPS environments:

- **VPS Database (`operational_db`)**: Runs in `DB_MODE=operational`. It hosts only `account` and `prompt` schemas. It skips Graph-RAG schemas, Apache AGE, and pgvector extensions to save memory and CPU on the VPS.
- **Laptop Database (`knowledge_db`)**: Runs in `DB_MODE=knowledge` on port `5433`. It hosts the Graph-RAG schema, Apache AGE graph representation, and pgvector embeddings.
- **Local Development Database (`llm_council_db`)**: Runs in `DB_MODE=full` on port `5432`, containing all schemas and extensions for unified local development.

---

## Startup & Deployment Options

Semantic option manifests live under [`options/`](options/) and shared non-secret environment layers live under [`env/`](env/). Each option may also have an untracked `options\<option>\.env` file for option-owned secrets. Local Compose options start through [`scripts/start.bat`](scripts/start.bat) or [`scripts/start.sh`](scripts/start.sh). VPS deployment options use [`scripts/deploy-vps.bat`](scripts/deploy-vps.bat).

Render an option without starting containers:

```bat
scripts\config.bat prod-full-local-http
scripts\config.bat prod-lite-local
scripts\config.bat dev-full-http
scripts\config.bat prod-full-local-observability
```

```sh
./scripts/config.sh prod-full-local-http
./scripts/config.sh prod-lite-local
./scripts/config.sh dev-full-http
./scripts/config.sh prod-full-local-observability
```

Run prerequisite and required-secret checks:

```bat
scripts\doctor.bat prod-full-local-http
scripts\doctor.bat prod-lite-local
```

```sh
./scripts/doctor.sh prod-full-local-http
./scripts/doctor.sh prod-lite-local
```

Generated diagnostics are written under `.generated/<option>/` and are ignored.

Start a local Compose option:

```bat
scripts\start.bat prod-full-local-http
scripts\start.bat prod-lite-local
scripts\start.bat prod-full-local-https
scripts\start.bat prod-full-local-https-tunnel
scripts\start.bat dev-full-http
scripts\start.bat dev-local-ai
scripts\start.bat prod-full-local-observability
scripts\start.bat prod-full-local-http --dry-run
```

Generate local TLS material when using HTTPS options:

```bat
scripts\generate-local-tls.bat
```

### Option Catalog

| Option | Command | Purpose |
|---|---|---|
| `dev-full-http` | `scripts\start.bat dev-full-http` | Full Docker-managed local development stack. |
| `dev-local-ai` | `scripts\start.bat dev-local-ai` | Ollama plus local observability for IDE-hosted `local-ai-service`. |
| `prod-full-local-http` | `scripts\start.bat prod-full-local-http` | Production-like local HTTP stack behind the Nginx Portal edge. |
| `prod-lite-local` | `scripts\start.bat prod-lite-local` | Full-capability production-lite local stack for constrained laptops; excludes observability containers by default. |
| `prod-full-local-https` | `scripts\start.bat prod-full-local-https` | Production-like local HTTPS stack behind the Nginx Portal edge. |
| `prod-full-local-https-tunnel` | `scripts\start.bat prod-full-local-https-tunnel` | HTTPS stack with Cloudflare tunnel sidecar. |
| `prod-full-local-observability` | `scripts\start.bat prod-full-local-observability` | Production-like HTTP stack with local observability and file-log overlays. |
| `prod-lite-vps` | `scripts\deploy-vps.bat prod-lite-vps` | VPS deployment without the laptop local-AI sidecar. |
| `prod-lite-vps-hybrid` | `scripts\deploy-vps.bat prod-lite-vps-hybrid` | VPS deployment paired with `scripts\laptop-local-ai.bat prod-lite-vps-hybrid`. |

---

## VPS Deployment Prerequisites

1. Ensure [`hostInfo.txt`](../hostInfo.txt) exists in the parent directory and contains the target VPS connection details.
2. Create `options\prod-lite-vps\.env` or `options\prod-lite-vps-hybrid\.env` from [`env/secrets.example.env`](env/secrets.example.env), then populate the required deployment secrets.
3. Run `scripts\deploy-vps.bat prod-lite-vps -UseHostPassword` or `scripts\deploy-vps.bat prod-lite-vps-hybrid -UseHostPassword`.
4. For the hybrid laptop worker, run `scripts\laptop-local-ai.bat prod-lite-vps-hybrid` after the VPS side is reachable.

For detailed steps, safety regulations, and firewall requirements, refer to the [VPS Integration and Deployment Runbook](../llm-council-docs/docs/runbooks/vps-integration-deployment.md).
