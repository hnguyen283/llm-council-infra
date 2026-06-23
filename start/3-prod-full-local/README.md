# Option 3: Local Production Run

This option runs the production topology locally in its most secure posture: only the edge API Gateway (port 8080) is published to the host, and all other ports (Postgres, Valkey, Kafka, config/discovery servers, Ollama) are kept unpublished.

## Files
- [prod.cmd](file:///d:/Project/LLMCouncil/llm-council-infra/start/3-prod-full-local/prod.cmd): Packages service JARs and starts the full split-production topology.
- [.env](file:///d:/Project/LLMCouncil/llm-council-infra/start/3-prod-full-local/.env): Environment configuration template.

## How to Run
1. Navigate to this directory in your terminal.
2. Run `.\prod.cmd` to compile, package, and launch the production stack.
3. Interact with the application through the API Gateway at http://localhost:8080.
