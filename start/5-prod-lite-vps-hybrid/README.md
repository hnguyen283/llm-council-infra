# Option 5: Local Production Lite VPS Hybrid

This option runs a hybrid setup where the core runtime services run on the remote VPS (deployed via `deploy-vps.cmd`), while the heavy AI Ollama workloads and the admin UI run locally on your laptop.

An SSH tunnel is established to bridge the local laptop-side components to the VPS Kafka message broker.

## Files
- [deploy-vps.cmd](file:///d:/Project/LLMCouncil/llm-council-infra/start/5-prod-lite-vps-hybrid/deploy-vps.cmd): Deploys the VPS component using SSH/SCP.
- [laptop-local-ai.cmd](file:///d:/Project/LLMCouncil/llm-council-infra/start/5-prod-lite-vps-hybrid/laptop-local-ai.cmd): Starts the local side of the deployment, including the local database, local Ollama container, local observability tools (AGE Viewer, Arize Phoenix), and the `local-ai-service`.
- [.env](file:///d:/Project/LLMCouncil/llm-council-infra/start/5-prod-lite-vps-hybrid/.env): Environment configuration template containing remote and database secrets.

## How to Run
1. Ensure `hostInfo.txt` exists in the parent directory (`d:\Project\LLMCouncil\hostInfo.txt`) containing the target VPS connection details.
2. Navigate to this directory in your terminal.
3. Run `.\deploy-vps.cmd` to deploy the core services to the VPS.
4. Run `.\laptop-local-ai.cmd` to start the local AI workloads, local DB, local observability tools, and connect them to the VPS via SSH tunnel.
