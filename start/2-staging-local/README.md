# Option 2: Local Staging

This option is used to run the production topology locally on your laptop, complete with local observability tools and log file access.

## Files
- [prod-overlays.cmd](file:///d:/Project/LLMCouncil/llm-council-infra/start/2-staging-local/prod-overlays.cmd): Starts all Compose projects in the split-production topology, applying overlays that publish observability tools on the loopback interface (Prometheus, Zipkin, VictoriaLogs, Alloy) and developer consoles (AGE Viewer, Arize Phoenix).
- [.env](file:///d:/Project/LLMCouncil/llm-council-infra/start/2-staging-local/.env): Environment configuration template.

## How to Run
1. Navigate to this directory in your terminal.
2. Run `.\prod-overlays.cmd` to compile, package, and launch the full stack with local observability tools.
3. Access telemetry and developer endpoints on:
   - Prometheus: http://localhost:9090
   - Zipkin: http://localhost:9411
   - VictoriaLogs UI: http://localhost:9428/select/vmui/
   - Graph Viewer (AGE Viewer): http://localhost:3001
   - Trace Evaluator (Arize Phoenix): http://localhost:6006

