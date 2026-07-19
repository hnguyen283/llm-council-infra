# prod-full-local-https-tunnel

Production-like public HTTPS stack with a remotely managed Cloudflare Tunnel
sidecar. Cloudflare terminates browser TLS for `https://llm.welllifeapp.com`;
the outbound-only connector shares the production Nginx edge network namespace
and forwards to `http://localhost:8080`, never to an Angular development
server. In this sidecar layout, loopback resolves to `portal-edge` rather than
to an unrelated host service.

Store `CLOUDFLARED_TUNNEL_TOKEN` only in this option's ignored `.env`. The
sidecar passes it to `cloudflared` as `TUNNEL_TOKEN`, uses the official named
`tunnel run` command, and exposes no token in its command line.

The remotely managed published application route in Cloudflare must use:

```text
Hostname: llm.welllifeapp.com
Service:  http://localhost:8080
```

`LOCAL_SERVICE_MAPPING` is a tracked assertion of that remote Cloudflare
setting. Changing the published application route in Cloudflare requires the
same change here and a fresh end-to-end smoke test.
