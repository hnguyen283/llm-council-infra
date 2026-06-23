# Option 4: Local Production Lite VPS

This option deploys the runtime environment (without Ollama or local UI static files hosting) to a remote VPS server.

## Files
- [deploy-vps.cmd](file:///d:/Project/LLMCouncil/llm-council-infra/start/4-prod-lite-vps/deploy-vps.cmd): Invokes the PowerShell deployment helper script to build Maven JARs, package files, and deploy to the remote VPS using SSH/SCP.
- [prod-lite.sh](file:///d:/Project/LLMCouncil/llm-council-infra/start/4-prod-lite-vps/prod-lite.sh): Asset copied and executed on the remote VPS to bootstrap the Docker containers.
- [.env](file:///d:/Project/LLMCouncil/llm-council-infra/start/4-prod-lite-vps/.env): Environment configuration template containing remote and database secrets.

## How to Run
1. Ensure `hostInfo.txt` exists in the parent directory (`d:\Project\LLMCouncil\hostInfo.txt`) containing the target VPS connection details.
2. Navigate to this directory in your terminal.
3. Run `.\deploy-vps.cmd` to start the remote deployment.
4. Pass `-DryRun` to dry-run the deployment steps.
