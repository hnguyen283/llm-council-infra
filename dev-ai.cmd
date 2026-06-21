@echo off
REM ============================================================================
REM dev-ai.cmd  --  Start Ollama (with GPU passthrough) for dev IDE work.
REM
REM Companion to dev.cmd. dev.cmd brings up infra (kafka/zipkin/discovery)
REM but intentionally skips Ollama because GPU passthrough requires the
REM NVIDIA Container Toolkit on the host. This script handles that piece
REM separately so devs without a CUDA-capable GPU can stick to dev.cmd
REM and the deterministic mock fallback in LocalAiClient.
REM
REM After this completes, run local-ai-service from your IDE with
REM   OLLAMA_BASE_URL=http://localhost:11434
REM in the IDE Run configuration.
REM ============================================================================

setlocal
cd /d "%~dp0"
set "ROOT=%~dp0"
set "ENV_FILE=%ROOT%.env"
set "AI_FILES=-f projects\ai-runtime\docker-compose.yml -f projects\ai-runtime\overlays\dev-ports.yml"

echo.
echo === [dev-ai] Ensuring llm-council-ai-runtime network exists ===
docker network inspect llm-council-ai-runtime >NUL 2>&1
if errorlevel 1 (
    docker network create -d bridge llm-council-ai-runtime >NUL
    echo Created network llm-council-ai-runtime.
)

echo.
echo === [dev-ai] Checking for Ollama image on this host ===
docker image inspect ollama/ollama:0.5.7 >NUL 2>&1
if errorlevel 1 (
    echo Ollama image is NOT present locally. `docker compose up` will pull it
    echo from Docker Hub, which requires internet access. Pull size is ~2 GB
    echo plus the deepseek-r1:7b model on first run.
    echo.
) else (
    echo Ollama image cached locally — no pull required.
)

echo.
echo === [dev-ai] Starting ollama (GPU passthrough, waiting for healthy) ===
docker compose --env-file "%ENV_FILE%" %AI_FILES% up -d --wait ollama
if errorlevel 1 (
    echo.
    echo Failed to start ollama or healthcheck timed out. Common causes:
    echo   - Image pull failed: Docker Hub unreachable, no internet.
    echo   - NVIDIA Container Toolkit not installed on the host.
    echo   - On Windows: NVIDIA driver missing on the *Windows* host ^(not WSL^).
    echo   - Docker Desktop WSL2 backend not enabled.
    echo.
    echo Inspect:  docker compose --env-file "%ENV_FILE%" %AI_FILES% logs ollama
    exit /b 1
)

echo.
echo === [dev-ai] Pulling deepseek-r1:7b (idempotent) ===
docker compose --env-file "%ENV_FILE%" %AI_FILES% exec ollama ollama pull deepseek-r1:7b
if errorlevel 1 ( echo Model pull failed. Aborting. & exit /b 1 )

echo.
echo === [dev-ai] Creating planner alias from /Modelfile.planner (idempotent) ===
docker compose --env-file "%ENV_FILE%" %AI_FILES% exec ollama ollama create planner -f /Modelfile.planner
if errorlevel 1 ( echo Create failed. Aborting. & exit /b 1 )

echo.
echo Ollama is ready. Next steps:
echo   1. In your IDE Run config for local-ai-service, set:
echo        OLLAMA_BASE_URL=http://localhost:11434
echo   2. Launch local-ai-service alongside config-server.
echo.
echo   Stop ollama:  docker compose --env-file "%ENV_FILE%" %AI_FILES% stop ollama

endlocal
