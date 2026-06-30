# Start Options

The pre-BP1.75 standardization introduces semantic start options under
`options/`. Each option is described by three simple files:

- `option.env` for option-owned, non-secret overrides.
- optional untracked `.env` for option-owned local secrets.
- `compose.files` for ordered Compose files, one path per line.
- `profiles.txt` for optional capability profiles, one name per line.

The implemented options render the existing `projects/*` Compose topology
behind one option model.

| Option | Purpose | UI runtime | Status |
|---|---|---|---|
| `prod-full-local-http` | Production-like local stack on HTTP. | `nginx-static` | Starts through `scripts\start.*`; Nginx Portal edge owns browser routes. |
| `prod-full-local-https` | Production-like local stack on HTTPS. | `nginx-static` | Starts through `scripts\start.*`; requires local TLS material. |
| `prod-full-local-https-tunnel` | HTTPS stack with optional tunnel sidecar. | `nginx-static` | Starts through `scripts\start.*`; tunnel forwards to Nginx edge. |
| `prod-full-local-observability` | HTTP stack with loopback observability and log-file overlays. | `nginx-static` | Replaces the old local staging overlay script. |
| `prod-lite-local` | Full-capability local production-lite stack for constrained laptops; GraphRAG and AI workers stay enabled while observability containers are excluded by default. | `nginx-static` | Starts through `scripts\start.*`; use `scripts\doctor.*` first. |
| `dev-full-http` | Docker-managed local stack for development. | `angular-dev-server` | Starts through `scripts\start.*`; not production-like. |
| `dev-local-ai` | Ollama and local observability helpers for IDE workflows. | n/a | Starts through `scripts\start.*`; prepares the planner model alias. |
| `prod-lite-vps` | VPS deployment runtime. | static files on VPS | Deploy through `scripts\deploy-vps.bat prod-lite-vps`. |
| `prod-lite-vps-hybrid` | VPS deployment plus laptop local-AI worker. | static files on VPS | Deploy through `scripts\deploy-vps.bat`; run laptop worker through `scripts\laptop-local-ai.bat`. |

The legacy ordinal `start/*` tree has been removed. Historical roadmap reports
may still mention the old commands as past validation evidence.
