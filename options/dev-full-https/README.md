# dev-full-https

Docker-managed development stack with the Portal Angular dev server exposed at
`https://localhost:4200`. It uses the same local certificate material as the
production-like HTTPS option and proxies browser API routes to the in-network
API Gateway. It is intentionally not production-like.

Provide non-empty `cert.pem` and `key.pem`, then run:

```bat
scripts\generate-local-tls.bat
scripts\start.bat dev-full-https
```

`mkcert` remains the recommended way to avoid browser warnings, but trusted
`localhost` identity is not a validation prerequisite. This option declares
`LOCAL_TLS_TRUST_REQUIRED=false`; set it to `true` explicitly for a strict
browser-trust run.

```sh
./scripts/generate-local-tls.sh
./scripts/start.sh dev-full-https
```

The generator refuses to overwrite existing TLS material. To preserve an
existing `ssl/` certificate, generate into `ssl-local/` and set
`HTTPS_CERT_DIR=../ssl-local` in this option's untracked `.env`.
