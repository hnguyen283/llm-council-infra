# prod-full-local-http

Transitional pre-BP1.75 option for the current full local production stack.

This option renders the canonical backend/data/messaging/observability/platform
Compose topology through the layered environment and manifest contract. It
builds the Portal UI and serves it through the local Nginx edge.

Run:

```bat
scripts\config.bat prod-full-local-http
scripts\doctor.bat prod-full-local-http
```

```sh
./scripts/config.sh prod-full-local-http
./scripts/doctor.sh prod-full-local-http
```
