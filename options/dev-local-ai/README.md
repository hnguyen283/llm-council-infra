# dev-local-ai

Starts the local AI companion runtime for IDE workflows:

- Ollama with the development port exposed on `127.0.0.1:11434`.
- AGE Viewer and Arize Phoenix local observability helpers.
- The `deepseek-r1:7b` model and `planner` alias are prepared after startup.

Run from `llm-council-infra`:

```bat
scripts\start.bat dev-local-ai
```

Then run `local-ai-service` from the IDE with `OLLAMA_BASE_URL=http://localhost:11434`.
