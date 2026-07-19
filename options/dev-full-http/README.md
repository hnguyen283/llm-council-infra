# dev-full-http

Docker-managed development stack with the Portal Angular dev server exposed at
`http://localhost:4200`. The dev server proxies browser API routes to the
in-network API Gateway, so it is launched by the same semantic option command
as the backend. It is intentionally not production-like.

Run:

```bat
scripts\start.bat dev-full-http
```

```sh
./scripts/start.sh dev-full-http
```
