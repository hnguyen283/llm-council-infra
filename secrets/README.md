# Secrets

This directory documents the target file-backed secret layout. Real local
secret files belong under `secrets/local/`, which is ignored.

Examples:

- `secrets/local/postgres-password.txt`
- `secrets/local/account-db-password.txt`
- `secrets/local/tenant-namespace-hmac-key.txt`
- `secrets/local/auth-jwt-private-key.pem`

Services still need progressive application changes before every secret can be
consumed through `_FILE` settings or `/run/secrets/*`.
