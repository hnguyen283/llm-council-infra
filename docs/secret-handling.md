# Secret Handling

Tracked env files must contain only non-secret defaults, option selections, or
blank example placeholders.

Use these locations for real local values during the transition:

- `env/workspace.env`
- `env/local.user.override.env`
- existing ignored option `.env` files while legacy scripts still require them

The target model is file-backed Docker secrets under `secrets/local/`, mounted
only into the services that require each value. The current implementation keeps
env-var compatibility because several services still read secrets directly from
process environment variables. New tracked env and option files are guarded by
`scripts/check-env.*` so secret-like tracked values must remain blank.

The BP1.5-required `TENANT_NAMESPACE_HMAC_KEY` is classified as a secret. It
must be present for production-like tenant namespace isolation checks and must
not be committed with a real value.
