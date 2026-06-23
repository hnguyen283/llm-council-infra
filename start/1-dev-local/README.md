# Option 1: Local Development

This option is used to run the runtime dependencies (PostgreSQL, Valkey, Kafka, Zipkin, etc.) locally in Docker so you can run the LLMCouncil Java services and admin UI from your IDE.

## Files
- [dev.cmd](file:///d:/Project/LLMCouncil/llm-council-infra/start/1-dev-local/dev.cmd): Starts the backend infrastructure containers (Postgres, Valkey, Kafka, Zipkin, Discovery Server, and Graph-RAG services).
- [dev-ai.cmd](file:///d:/Project/LLMCouncil/llm-council-infra/start/1-dev-local/dev-ai.cmd): Starts the Ollama container (supports GPU passthrough), pulls/prepares the DeepSeek model for local AI processing, and boots up the local observability tools (AGE Viewer & Arize Phoenix).
- [.env](file:///d:/Project/LLMCouncil/llm-council-infra/start/1-dev-local/.env): Environment configuration template.

## How to Run
1. Navigate to this directory in your terminal.
2. Run `.\dev.cmd` to start the core infrastructure.
3. Run `.\dev-ai.cmd` if you need local Ollama AI processing and RAG/Graph tracing.
4. Launch `config-server` and your target services from your IDE.
5. Access developer portals:
   - Graph Viewer (AGE Viewer): http://localhost:3001
   - Trace Evaluator (Arize Phoenix): http://localhost:6006

