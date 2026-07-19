# Secret Handling

Tracked env files must contain only non-secret defaults, option selections, or
blank example placeholders.

Use these locations for real local values during the transition:

- `env/workspace.env`
- `env/local.user.override.env`
- existing ignored option `.env` files while legacy scripts still require them

The first file-backed vertical slice is the API Gateway internal JWT key pair:

- `secrets/local/api-gateway/private-key.pem`
- `secrets/local/api-gateway/public-keys.pem`

Only `api-gateway` receives that directory at `/run/secrets/api-gateway`. Raw
PEM files take precedence when present. The existing base64 environment values
remain a rollback-compatible fallback while other services are migrated.
Generated diagnostics never persist either delivery mechanism's value.

Other secrets remain on the documented untracked-env compatibility path until
their owning services add an equivalent file-backed contract. New tracked env
and option files are guarded by `scripts/check-env.*`; secret-like values must
remain blank, while non-secret `*_FILE` paths are allowed.

The BP1.5-required `TENANT_NAMESPACE_HMAC_KEY` is classified as a secret. It
must be present for production-like tenant namespace isolation checks and must
not be committed with a real value.
