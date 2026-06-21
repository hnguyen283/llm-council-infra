@echo off
REM ============================================================================
REM dev.cmd  --  Rebuild and run INFRA ONLY in Docker (dev env, new project
REM             layout). Brings up the runtime dependencies an IDE-launched
REM             service needs from outside the container set:
REM
REM   discovery-server, kafka (KRaft), zipkin, postgres, valkey
REM
REM Note: config-server is NOT started here. Run it from your IDE alongside
REM the service you're editing -- it's the first thing to start.
REM
REM This script does NOT start the `ollama` container (GPU passthrough is not
REM assumed on every dev machine). Use `dev-ai.cmd` separately if you need
REM real local AI inference.
REM ============================================================================

setlocal
cd /d "%~dp0"
set "ROOT=%~dp0"
set "ENV_FILE=%ROOT%.env"

set "DATA_FILES=-f projects\data\docker-compose.yml -f projects\data\overlays\dev-ports.yml"
set "MESSAGING_FILES=-f projects\messaging\docker-compose.yml -f projects\messaging\overlays\dev-ports.yml"
set "OBS_FILES=-f projects\observability\docker-compose.yml -f projects\observability\overlays\dev-ports.yml"
set "PLAT_FILES=-f projects\platform\docker-compose.yml -f projects\platform\overlays\dev-ports.yml"
set "GRAPHRAG_FILES=-f projects\graphrag\docker-compose.yml -f projects\graphrag\overlays\dev-ports.yml"

echo.
echo === [dev] Ensuring external Docker networks exist ===
for %%N in (data messaging observability platform app ai-runtime) do (
    docker network inspect llm-council-%%N >NUL 2>&1
    if errorlevel 1 (
        docker network create -d bridge llm-council-%%N >NUL
        echo Created network llm-council-%%N.
    )
)

echo.
echo === [dev] Tearing down existing dev infra ===
docker compose --env-file "%ENV_FILE%" %PLAT_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %OBS_FILES%       down --remove-orphans
docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES%  down --remove-orphans
docker compose --env-file "%ENV_FILE%" %MESSAGING_FILES% down --remove-orphans
docker compose --env-file "%ENV_FILE%" %DATA_FILES%      down --remove-orphans

echo.
echo === [dev] Rebuilding discovery-server image (no cache) ===
docker compose --env-file "%ENV_FILE%" %PLAT_FILES% build --no-cache discovery-server
if errorlevel 1 ( echo Build failed. Aborting. & exit /b 1 )

echo.
echo === [dev] Bringing up postgres + valkey ===
docker compose --env-file "%ENV_FILE%" %DATA_FILES% up -d --wait postgres valkey
if errorlevel 1 ( echo Data infra failed. Aborting. & exit /b 1 )

echo.
echo === [dev] Ensuring Postgres application roles and schemas ===
docker compose --env-file "%ENV_FILE%" %DATA_FILES% exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
if errorlevel 1 ( echo Postgres bootstrap failed. Aborting. & exit /b 1 )

echo.
echo === [dev] Bringing up kafka (KRaft single-node) ===
docker compose --env-file "%ENV_FILE%" %MESSAGING_FILES% up -d --wait kafka
if errorlevel 1 ( echo Messaging infra failed. Aborting. & exit /b 1 )

echo.
echo === [dev] Bringing up zipkin (observability, others on demand) ===
docker compose --env-file "%ENV_FILE%" %OBS_FILES% up -d --wait zipkin
if errorlevel 1 ( echo Zipkin failed. Aborting. & exit /b 1 )

echo.
echo === [dev] Bringing up discovery-server (--no-deps: skip config-server dep) ===
docker compose --env-file "%ENV_FILE%" %PLAT_FILES% up -d --no-deps discovery-server
if errorlevel 1 ( echo discovery-server failed. Aborting. & exit /b 1 )

findstr /i /c:"GRAPHRAG_ENABLED=true" "%ENV_FILE%" >nul 2>&1
if not errorlevel 1 (
    echo.
    echo === [dev] Bringing up Graph-RAG services ===
    docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES% build
    docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES% up -d --wait graphrag-retrieval-service graphrag-indexing-worker
    if errorlevel 1 ( echo Graph-RAG services failed. Aborting. & exit /b 1 )
)

echo.
echo Infra is up. Next steps:
echo   1. Launch config-server from your IDE in the llm-council repo (port 8888).
echo   2. Launch the app service^(s^) you're editing from your IDE.
echo.
echo   Tear down everything:
echo     docker compose --env-file "%ENV_FILE%" %PLAT_FILES% down
echo     docker compose --env-file "%ENV_FILE%" %OBS_FILES% down
echo     docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES% down
echo     docker compose --env-file "%ENV_FILE%" %MESSAGING_FILES% down
echo     docker compose --env-file "%ENV_FILE%" %DATA_FILES% down

endlocal
