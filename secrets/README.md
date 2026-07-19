# Secrets

This directory documents the target file-backed secret layout. Real local
secret files belong under `secrets/local/`, which is ignored.

Examples:

- `secrets/local/postgres-password.txt`
- `secrets/local/account-db-password.txt`
- `secrets/local/tenant-namespace-hmac-key.txt`
- `secrets/local/auth-jwt-private-key.pem`

Implemented first slice:

- `secrets/local/api-gateway/private-key.pem`
- `secrets/local/api-gateway/public-keys.pem`

The gateway reads raw PEM content from those service-scoped mounts when the
files are present and falls back to the existing base64 environment variables
when they are absent. Never copy the private key into an example or diagnostic
file. Other services still need progressive application changes before every
secret can be consumed through `_FILE` settings or `/run/secrets/*`.
