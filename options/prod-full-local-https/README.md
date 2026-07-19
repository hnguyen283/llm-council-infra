# prod-full-local-https

Production-like local stack with the Portal UI built into an Nginx edge and
served at `https://localhost:8443`.

Requires non-empty `cert.pem` and `key.pem` under `llm-council-infra/ssl` or a
custom `HTTPS_CERT_DIR` because Nginx cannot start its HTTPS listener without
them. Browser identity/trust validation is retained as an optional diagnostic:
this option sets `LOCAL_TLS_TRUST_REQUIRED=false`, so `scripts/doctor.*` warns
instead of failing when the certificate is not trusted for `localhost`.

Set `LOCAL_TLS_TRUST_REQUIRED=true` as an explicit environment override when a
release or security-focused run must enforce strict local browser trust.

The TLS generator refuses to overwrite existing material. If `ssl/` already
contains a certificate for another environment, generate into `ssl-local/` and
set `HTTPS_CERT_DIR=../ssl-local` in this option's untracked `.env`.
