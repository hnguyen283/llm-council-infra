# Local HTTPS

`prod-full-local-https` terminates TLS at the local Nginx edge, and
`dev-full-https` terminates TLS in the Compose-managed Angular development
server. The tunnel option terminates browser TLS at Cloudflare and uses private
HTTP to the Nginx edge.

Generate local TLS material:

```bat
scripts\generate-local-tls.bat
```

```sh
./scripts/generate-local-tls.sh
```

The helper uses `mkcert` because it can create locally trusted certificates.
Generated files are ignored under `ssl/`.

Expected files:

- `ssl/cert.pem`
- `ssl/key.pem`

Use `HTTPS_CERT_DIR` in `env/workspace.env` when the files live somewhere else.

Certificate and key files remain structurally required for options that listen
on local HTTPS. Browser identity/trust is optional for general validation:
`prod-full-local-https` and `dev-full-https` set
`LOCAL_TLS_TRUST_REQUIRED=false`, so `doctor` reports a warning without failing.
Set the variable to `true` for an explicit strict local-browser security run.
