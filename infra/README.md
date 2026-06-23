# Infrastructure Resources & Configuration

This directory contains container definition templates, bootstrap logic, collector configs, and experimental benchmarks for the LLM Council infrastructure.

---

## Directory Layout

### 1. [postgres/](postgres/)
Contains the customized PostgreSQL database engine with graph database capabilities (Apache AGE) and vector search capabilities (pgvector):
*   `Dockerfile` — Extends Postgres 16 with Apache AGE and pgvector extensions compiled from source.
*   [`initdb/00_init.sh`](postgres/initdb/00_init.sh) — Idempotent bootstrap script executing on first database start. Dynamically prepares roles (`ACCOUNT_DB_USER`, `PROMPT_DB_USER`, `GRAPHRAG_DB_USER`) and separates schemas according to the target environment profile (`DB_MODE` = `full`, `operational`, or `knowledge`).

### 2. [alloy/](alloy/)
Hosts configuration files and telemetry forwarding rules for **Grafana Alloy** collector. Alloy dynamically scrapes metrics from application services, aggregates log files from the host log mounts, and ships them directly into VictoriaLogs and Prometheus.

### 3. [prometheus.yml](prometheus.yml)
Centralized scrape configuration for Prometheus, defining scrape intervals, target instances, and metrics path targets for the Spring Boot application actuator endpoints and Graph-RAG Python service endpoints.

### 4. [spike/](spike/)
Playground folder containing experimental scripts, benchmark tools, and Cypher/SQL queries used to profile Ollama performance, model parameters, and knowledge graph response calibration.
