# Local HTTPS

`prod-full-local-https` and `prod-full-local-https-tunnel` terminate TLS at
the local Nginx edge. Internal containers continue to communicate over the
Docker network.

Generate local TLS material:

```bat
scripts\generate-local-tls.bat
```

```sh
./scripts/generate-local-tls.sh
```

The helper prefers `mkcert` because it can create locally trusted certificates.
If `mkcert` is unavailable, it falls back to OpenSSL self-signed material. The
generated files are ignored under `ssl/`.

Expected files:

- `ssl/cert.pem`
- `ssl/key.pem`

Use `HTTPS_CERT_DIR` in `env/workspace.env` when the files live somewhere else.
