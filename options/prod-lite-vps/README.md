# prod-lite-vps

Deploys the production-lite VPS runtime through the standardized option model.

Create an untracked runtime environment file:

```bat
copy env\secrets.example.env options\prod-lite-vps\.env
```

Populate the required values, then deploy from `llm-council-infra`:

```bat
scripts\deploy-vps.bat prod-lite-vps -UseHostPassword
```

The deployment helper streams secrets over SSH and does not copy `.env` to the VPS.
