# Environment Catalog

This catalog records the first pre-BP1.75 variable classification pass. It is
intentionally focused on variables touched by BP1.5 and the current production
startup path.

## Precedence

Official options load interpolation-time env files from lowest to highest
precedence:

1. `env/defaults.env`
2. `env/workspace.env` when present
3. `env/modes/<http-or-https>.env`
4. `options/<option-name>/option.env`
5. `env/local.user.override.env` when present
6. Explicit shell or CLI environment

Generated diagnostics are written under `.generated/<option>/` and are ignored.

## Classification

| Variable | Class | Owner | Notes |
|---|---|---|---|
| `PUBLIC_SCHEME`, `PUBLIC_HOST`, `PUBLIC_PORT`, `PUBLIC_ORIGIN` | Mode/option non-secret | Edge option | Must become the single source for UI, CORS, callback, and cookie derivation in later phases. |
| `CORS_ALLOWED_ORIGINS` | Mode default | Gateway/auth runtime | Currently duplicated because services consume a literal list; Phase 3 should derive from public origin plus documented dev origins. |
| `AUTH_COOKIE_SECURE` | Mode default | auth-service | HTTP false, HTTPS true. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Global non-secret default | Observability | Defaults to the in-stack Zipkin OTLP endpoint; BP1.75 may override with collector. |
| `TENANT_NAMESPACE_HMAC_KEY` | Secret | BP1.5 tenant isolation | Required for tenant-safe namespace derivation; never tracked with a real value. |
| `ACCOUNT_INTERNAL_SERVICE_TOKEN` | Secret | BP1.5 internal auth | Interim shared-token compatibility while internal JWT paths are used where available. |
| `AUTH_JWT_PRIVATE_KEY_PEM`, `AUTH_JWT_PUBLIC_KEYS_PEM` | Secret | auth-service | Existing RSA/JWKS signing material. |
| `GATEWAY_INTERNAL_PRIVATE_KEY_PEM`, `GATEWAY_INTERNAL_PUBLIC_KEYS_PEM` | Secret | api-gateway | Existing internal JWT signing material. |
| `POSTGRES_PASSWORD`, `ACCOUNT_DB_PASSWORD`, `PROMPT_DB_PASSWORD`, `VALKEY_PASSWORD` | Secret | data tier | Required by current containers. |
| `GEMINI_API_KEY`, `OPENAI_API_KEY` | Secret | AI workers | Optional for local mock/fallback paths, required for provider-backed runs. |
| `GRAPHRAG_MODE`, `GRAPHRAG_ENABLED` | Option/runtime non-secret | Graph-RAG option | Transitional dual flag. `GRAPHRAG_MODE` owns semantics; `GRAPHRAG_ENABLED` remains for existing services. |

## Duplicate Rule

A tracked variable may appear in more than one file only when the later file is
an intentional override and this catalog names the owner. Unexplained duplicate
definitions are defects.
