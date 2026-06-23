# LLM Council — Infrastructure & Orchestration

This repository hosts all infrastructure scripts, Docker Compose files, overlays, and deployment tools for the **LLM Council** platform. The core application services and business logic reside in the sibling [`llm-council`](../llm-council) repository.

---

## Architecture Topology

The infrastructure is structured into **seven independent Compose projects** inside `projects/` that communicate over **six external Docker networks**:

| Project | Services | Compose File |
| :--- | :--- | :--- |
| `llm-council-data` | `postgres`, `valkey` | [`projects/data/docker-compose.yml`](projects/data/docker-compose.yml) |
| `llm-council-messaging` | `kafka` (Apache KRaft) | [`projects/messaging/docker-compose.yml`](projects/messaging/docker-compose.yml) |
| `llm-council-ai-runtime` | `ollama` | [`projects/ai-runtime/docker-compose.yml`](projects/ai-runtime/docker-compose.yml) |
| `llm-council-observability` | `zipkin`, `prometheus`, `victorialogs`, `alloy` | [`projects/observability/docker-compose.yml`](projects/observability/docker-compose.yml) |
| `llm-council-platform` | `config-server`, `discovery-server` | [`projects/platform/docker-compose.yml`](projects/platform/docker-compose.yml) |
| `llm-council-core` | `api-gateway` + 7 application services | [`projects/core/docker-compose.yml`](projects/core/docker-compose.yml) |
| `llm-council-graphrag` | `graphrag-retrieval-service`, `graphrag-indexing-worker` | [`projects/graphrag/docker-compose.yml`](projects/graphrag/docker-compose.yml) |

---

## Sibling Repository Convention

> [!IMPORTANT]
> **Build Context Dependency**
> Every application service in the Compose files uses relative paths targeting the sibling [`llm-council`](../llm-council) directory (e.g., `../../../llm-council/api-gateway`). Both repositories **must** reside in the same parent directory (`d:\Project\LLMCouncil\`).

---

## Database Isolation Architecture

To safeguard knowledge graph data and optimize costs, the database layer is split between the local (laptop) and VPS environments:

*   **VPS Database (`operational_db`)**: Runs in `DB_MODE=operational`. It hosts only `account` and `prompt` schemas. It skips Graph-RAG schemas, Apache AGE, and pgvector extensions to save memory and CPU on the VPS.
*   **Laptop Database (`knowledge_db`)**: Runs in `DB_MODE=knowledge` on port **5433** (to avoid port conflicts). It hosts the Graph-RAG schema, Apache AGE graph representation, and pgvector embeddings. It skips account and prompt schemas.
*   **Local Development Database (`llm_council_db`)**: Runs in `DB_MODE=full` on port **5432**, containing all schemas and extensions for a unified local development environment.

---

## Startup & Deployment Options

All entry points and configurations are structured under the [`start/`](start/) directory to isolate runtime contexts. Each subdirectory contains its own `.env` file template for local customization.

Navigate into one of the following directories under `start/` to run or deploy the stack:

### [1. Local Development](start/1-dev-local/)
Used to run dependencies (Postgres, Valkey, Kafka, Zipkin, etc.) locally in Docker so you can run the Java services and UI from your IDE.
*   `dev.cmd` — Starts backend infrastructure.
*   `dev-ai.cmd` — Starts Ollama and pulls the DeepSeek model.

### [2. Local Staging](start/2-staging-local/)
Runs the full production topology locally on your laptop with loopback observability tools enabled.
*   `prod-overlays.cmd` — Launches the production stack with Prometheus, Zipkin, and VictoriaLogs.

### [3. Local Production Run](start/3-prod-full-local/)
Runs the full production topology locally in its most secure posture (ports unpublished, except the API Gateway port 8080).
*   `prod.cmd` — Packages and launches the secure production stack.

### [4. Local Production Lite VPS](start/4-prod-lite-vps/)
Deploys the runtime environment (without Ollama or local UI static hosting) to a remote VPS server.
*   `deploy-vps.cmd` — Invokes the helper script to build and deploy to the VPS.
*   `prod-lite.sh` — Bootstraps Docker containers on the remote VPS.

### [5. Local Production Lite VPS Hybrid](start/5-prod-lite-vps-hybrid/)
A hybrid setup where core services run on the remote VPS (via `deploy-vps.cmd`), while heavy Ollama AI processing, local database, and admin UI run on your local laptop.
*   `deploy-vps.cmd` — Deploys the VPS side.
*   `laptop-local-ai.cmd` — Opens an SSH tunnel to the VPS Kafka, starts local Postgres knowledge_db on 5433, local Ollama, and local-ai-service.

---

## VPS Deployment Prerequisites

1.  Ensure [`hostInfo.txt`](../hostInfo.txt) exists in the parent directory (`d:\Project\LLMCouncil\`) containing the target VPS connection details.
2.  Navigate to either [`start/4-prod-lite-vps/`](start/4-prod-lite-vps/) or [`start/5-prod-lite-vps-hybrid/`](start/5-prod-lite-vps-hybrid/).
3.  Configure the local `.env` file in that directory.
4.  Run `.\deploy-vps.cmd` to start the deployment.

For detailed steps, safety regulations, and firewall requirements, refer to the [VPS Integration and Deployment Runbook](../llm-council-docs/docs/runbooks/vps-integration-deployment.md).
