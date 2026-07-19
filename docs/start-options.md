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
| `prod-full-local-https` | Production-like local stack on HTTPS. | `nginx-static` | Starts through `scripts\start.*`; cert/key files are required to listen, while browser identity/trust is an optional diagnostic unless explicitly enforced. |
| `prod-full-local-https-tunnel` | Public HTTPS stack with a remotely managed tunnel sidecar. | `nginx-static` | Cloudflare terminates browser TLS; the connector shares the Nginx edge network namespace so the remote `http://localhost:8080` route resolves to the production edge. |
| `prod-full-local-observability` | HTTP stack with loopback observability and log-file overlays. | `nginx-static` | Replaces the old local staging overlay script. |
| `prod-lite-local` | Full-capability local production-lite stack for constrained laptops; GraphRAG and AI workers stay enabled while observability containers are excluded by default. | `nginx-static` | Starts through `scripts\start.*`; use `scripts\doctor.*` first. |
| `dev-full-http` | Docker-managed local stack for development. | `angular-dev-server` | Backend and Portal dev server start together through `scripts\start.*`; not production-like. |
| `dev-full-https` | Secure-cookie/callback development over local TLS. | `angular-dev-server` | Backend and Portal dev server start together through `scripts\start.*`; browser identity/trust is optional and the mode is not production-like. |
| `dev-local-ai` | Ollama and local observability helpers for IDE workflows. | n/a | Starts through `scripts\start.*`; prepares the planner model alias. |
| `prod-lite-vps` | VPS deployment runtime. | static files on VPS | Deploy through `scripts\deploy-vps.bat prod-lite-vps`. |
| `prod-lite-vps-hybrid` | VPS deployment plus laptop local-AI worker. | static files on VPS | Deploy through `scripts\deploy-vps.bat`; run laptop worker through `scripts\laptop-local-ai.bat`. |

The legacy ordinal `start/*` tree has been removed. Historical roadmap reports
may still mention the old commands as past validation evidence.

`scripts/config.*` writes safe service/file/profile summaries plus a masked
environment summary under `.generated/<option>/`. Runtime commands reassemble
the validated Compose files and reapply environment layers in memory, so
secret values are not persisted in generated Compose diagnostics.

`mkcert` is recommended for warning-free local HTTPS but is not a graduation
gate. The helper refuses to overwrite existing certificate material; pass an
empty directory such as `ssl-local` and set `HTTPS_CERT_DIR=../ssl-local` in the
option's untracked `.env` when `ssl/` belongs to another environment.
