# prod-full-local-observability

Production-like local stack with operator observability conveniences:

- Nginx-served Portal UI on `http://localhost:8080`.
- Prometheus, Zipkin, and VictoriaLogs published on loopback.
- Local AGE Viewer and Arize Phoenix helpers.
- File-log overlays for platform/core/GraphRAG services.

Run from `llm-council-infra`:

```bat
scripts\start.bat prod-full-local-observability
```
