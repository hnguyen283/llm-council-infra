# prod-lite-vps-hybrid

Deploys the production-lite VPS runtime and supports a laptop-hosted local AI worker.

Create an untracked runtime environment file:

```bat
copy env\secrets.example.env options\prod-lite-vps-hybrid\.env
```

Deploy the VPS side:

```bat
scripts\deploy-vps.bat prod-lite-vps-hybrid -UseHostPassword
```

Run the laptop AI worker side:

```bat
scripts\laptop-local-ai.bat prod-lite-vps-hybrid
```
