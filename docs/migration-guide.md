# Infrastructure Standardization Migration Guide

This is the migration guide for the pre-BP1.75 infrastructure refactor.

## Current Boundary

The legacy ordinal `start/*` tree has been retired. All active local startup and
VPS deployment flows now enter through semantic options under `options/` and
shared scripts under `scripts/`.

| Legacy entry point | New semantic option | Current behavior |
|---|---|---|
| `start/3-prod-full-local/prod.cmd` | `prod-full-local-http` | Use `scripts\start.bat prod-full-local-http`. |
| `start/1-dev-local/dev.cmd` | `dev-full-http` | Use `scripts\start.bat dev-full-http`. |
| `start/1-dev-local/dev-ai.cmd` | `dev-local-ai` | Use `scripts\start.bat dev-local-ai`. |
| `start/2-staging-local/prod-overlays.cmd` | `prod-full-local-observability` | Use `scripts\start.bat prod-full-local-observability`. |
| `start/4-prod-lite-vps/deploy-vps.cmd` | `prod-lite-vps` | Use `scripts\deploy-vps.bat prod-lite-vps`. |
| `start/5-prod-lite-vps-hybrid/deploy-vps.cmd` | `prod-lite-vps-hybrid` | Use `scripts\deploy-vps.bat prod-lite-vps-hybrid`. |
| `start/5-prod-lite-vps-hybrid/laptop-local-ai.cmd` | `prod-lite-vps-hybrid` | Use `scripts\laptop-local-ai.bat prod-lite-vps-hybrid`. |

## New Commands

Render and validate a configured option:

```bat
scripts\config.bat prod-full-local-http
```

```sh
./scripts/config.sh prod-full-local-http
```

Run prerequisite checks and required-secret presence checks:

```bat
scripts\doctor.bat prod-full-local-http
```

```sh
./scripts/doctor.sh prod-full-local-http
```

Start a mapped option:

```bat
scripts\start.bat prod-full-local-http
scripts\start.bat dev-full-http
scripts\start.bat dev-local-ai
scripts\start.bat prod-full-local-observability
scripts\start.bat prod-full-local-http --dry-run
```

The POSIX `scripts/start.sh` follows the same semantic option flow as the
Windows wrapper.

Deploy a VPS option:

```bat
scripts\deploy-vps.bat prod-lite-vps -UseHostPassword
scripts\deploy-vps.bat prod-lite-vps-hybrid -UseHostPassword
scripts\laptop-local-ai.bat prod-lite-vps-hybrid
```

## Next Migration Gates

1. Move eligible application secrets from env-var compatibility to file-backed
   `_FILE` settings as each service supports them.
