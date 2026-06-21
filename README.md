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

## Environment Setup

1.  **Local Stack Secrets**: Copy [`.env.example`](.env.example) to `.env` in this directory:
    ```bash
    cp .env.example .env
    # Customize JWT keys, passwords, and API keys.
    ```
2.  **VPS Hybrid Secrets**: Customize `prod-lite.env` in this directory. This file remains on your laptop and is never copied to the VPS; its values are injected over SSH during deployment.
3.  **Local SSL**: Place certificates under `ssl/` inside this directory (gitignored).

---

## Orchestrator Scripts

All commands should be run from this repository root:

### 1. Local Development (`dev.cmd` & `dev-ai.cmd`)
Starts core infrastructure services (`postgres`, `valkey`, `kafka`, `zipkin`, `discovery-server`) and leaves your terminal free. Developers run `config-server` and application services directly from their IDE (using `llm-council` backend codebase).
*   `dev.cmd` — Brings up dev infrastructure.
*   `dev-ai.cmd` — Launches `ollama` with GPU passthrough and builds the `planner` model alias.

### 2. Local Production Run (`prod.cmd`)
Builds all Maven modules from the sibling repo, packages them, and brings up all projects containerized with strict health-gating:
```cmd
prod.cmd
```

### 3. Loopback Observability & Overlays
*   `prod-local-obs.cmd` — Production-like run publishing Zipkin, Prometheus, and VictoriaLogs (`vmui` at `http://127.0.0.1:9428/select/vmui/`) to loopback only.
*   `prod-overlays.cmd` — Production run with local observability and centralized log-file overlays enabled.

### 4. VPS Hybrid Laptop Worker (`laptop-local-ai.cmd`)
Launches the laptop-side local AI services for the VPS hybrid environment.
```cmd
laptop-local-ai.cmd
```
This script:
1.  Starts the local knowledge DB (`knowledge_db`) on port **5433**.
2.  Launches `ollama` and checks the local model alias.
3.  Opens an SSH tunnel forwarding laptop `127.0.0.1:9092` to VPS `127.0.0.1:9092` (using connection details in `../hostInfo.txt`).
4.  Starts `local-ai-service` in remote-worker mode, communicating through the SSH Kafka tunnel.

---

## VPS Deployment Guide

1.  Configure `../hostInfo.txt` and `prod-lite.env` locally on your laptop.
2.  Run the deployment script from the parent directory:
    ```cmd
    cd /d D:\Project\LLMCouncil
    deploy-vps.cmd
    ```
    This script builds JARs and UI bundles locally, bundles only safe non-secret artifacts, uploads the bundle to the VPS, injects the variables from `prod-lite.env` via SSH, and executes `prod-lite.sh` (VPS Compose orchestrator).

For detailed steps, safety regulations, and firewall requirements, refer to the [VPS Integration and Deployment Runbook](file:///d:/Project/LLMCouncil/llm-council-docs/docs/runbooks/vps-integration-deployment.md).
