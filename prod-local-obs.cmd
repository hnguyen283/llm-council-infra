@echo off
REM ============================================================================
REM prod-local-obs.cmd  --  Production stack with loopback observability access.
REM
REM Identical to prod.cmd EXCEPT the observability project layers
REM projects/observability/overlays/local-observability.yml on top of prod.yml,
REM publishing Prometheus, Zipkin, and VictoriaLogs on the host loopback
REM interface (${OBSERVABILITY_HOST_BIND:-127.0.0.1}) only. (Grafana + Loki
REM retired 2026-05-22 under the P1 critical-dependency replacement.)
REM
REM Security invariants vs. prod.cmd:
REM   - api-gateway:8080 still the only port reachable from anywhere besides
REM     the host itself.
REM   - Postgres, Valkey, Kafka, every Spring HTTP port, Ollama, config-server,
REM     discovery-server, and JDWP remain unpublished.
REM   - Observability ports are loopback-bound; a second machine on the LAN
REM     cannot reach them without an SSH tunnel or VPN.
REM   - If you set OBSERVABILITY_HOST_BIND to 0.0.0.0 or a routable IP, you
REM     are intentionally widening exposure; firewall accordingly.
REM ============================================================================

setlocal
cd /d "%~dp0"
set "ROOT=%~dp0"
set "ENV_FILE=%ROOT%.env"
set "WAIT_SECONDS=300"

set "DATA_DIR=projects\data"
set "DATA_FILES=-f %DATA_DIR%\docker-compose.yml"

set "MESSAGING_DIR=projects\messaging"
set "MESSAGING_FILES=-f %MESSAGING_DIR%\docker-compose.yml"

set "AI_DIR=projects\ai-runtime"
set "AI_FILES=-f %AI_DIR%\docker-compose.yml"

set "OBS_DIR=projects\observability"
set "OBS_FILES=-f %OBS_DIR%\docker-compose.yml -f %OBS_DIR%\overlays\prod.yml -f %OBS_DIR%\overlays\local-observability.yml"

set "PLAT_DIR=projects\platform"
set "PLAT_FILES=-f %PLAT_DIR%\docker-compose.yml -f %PLAT_DIR%\overlays\prod.yml"

set "CORE_DIR=projects\core"
set "CORE_FILES=-f %CORE_DIR%\docker-compose.yml -f %CORE_DIR%\overlays\prod.yml"

set "OBS_LINK_HOST=%OBSERVABILITY_HOST_BIND%"
if not defined OBS_LINK_HOST set "OBS_LINK_HOST=127.0.0.1"
if "%OBS_LINK_HOST%"=="0.0.0.0" set "OBS_LINK_HOST=127.0.0.1"
REM ADMIN_OBS_UI_DASHBOARD intentionally left empty by default — Perses
REM was skipped per the approved P1.6 fallback (02 §3.4), so there is no
REM dashboard URL to link to. App-native dashboard build is deferred to
REM P2/P3; until then the admin UI hides the Dashboard card.
if not defined ADMIN_OBS_UI_PROMETHEUS set "ADMIN_OBS_UI_PROMETHEUS=http://%OBS_LINK_HOST%:9090"
if not defined ADMIN_OBS_UI_ZIPKIN set "ADMIN_OBS_UI_ZIPKIN=http://%OBS_LINK_HOST%:9411"
if not defined ADMIN_OBS_UI_LOGS set "ADMIN_OBS_UI_LOGS=http://%OBS_LINK_HOST%:9428"
if not defined ADMIN_DASHBOARD_BASE_URL set "ADMIN_DASHBOARD_BASE_URL=/admin/observability"

call :main
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%

:main
echo.
echo === [prod-local-obs] Checking Docker Compose availability ===
docker compose version
if errorlevel 1 (
    echo Docker Compose is not available. Aborting.
    exit /b 1
)
call :check_docker_engine "prod-local-obs"
if errorlevel 1 exit /b 1

echo.
echo === [prod-local-obs] Verifying required secrets are present in .env ===
for %%V in (AUTH_JWT_PRIVATE_KEY_PEM AUTH_JWT_PUBLIC_KEYS_PEM GATEWAY_INTERNAL_PRIVATE_KEY_PEM GATEWAY_INTERNAL_PUBLIC_KEYS_PEM POSTGRES_PASSWORD ACCOUNT_DB_PASSWORD PROMPT_DB_PASSWORD VALKEY_PASSWORD ACCOUNT_INTERNAL_SERVICE_TOKEN) do (
    findstr /B /R /C:"%%V=." .env >NUL 2>&1
    if errorlevel 1 (
        echo ERROR: %%V is empty or missing from .env
        exit /b 1
    )
)

echo.
echo === [prod-local-obs] Ensuring external Docker networks exist ===
call :ensure_network llm-council-data
call :ensure_network llm-council-messaging
call :ensure_network llm-council-observability
call :ensure_network llm-council-platform
call :ensure_network llm-council-app
call :ensure_network llm-council-ai-runtime

echo.
echo === [prod-local-obs] Packaging service JARs from current source ===
pushd "%ROOT%..\llm-council"
call mvn -DskipTests package
if errorlevel 1 ( popd & echo Maven package failed. Aborting. & exit /b 1 )
popd
if errorlevel 1 ( echo Maven package failed. Aborting. & exit /b 1 )

echo.
echo === [prod-local-obs] Tearing down existing projects (reverse order) ===
docker compose --env-file "%ENV_FILE%" %CORE_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %PLAT_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %OBS_FILES%       down --remove-orphans
docker compose --env-file "%ENV_FILE%" %AI_FILES%        down --remove-orphans
docker compose --env-file "%ENV_FILE%" %MESSAGING_FILES% down --remove-orphans
docker compose --env-file "%ENV_FILE%" %DATA_FILES%      down --remove-orphans

echo.
echo === [prod-local-obs] Rebuilding project images (no cache) ===
docker compose --env-file "%ENV_FILE%" %PLAT_FILES% build --no-cache
if errorlevel 1 ( echo Platform build failed. Aborting. & exit /b 1 )
docker compose --env-file "%ENV_FILE%" %CORE_FILES% build --no-cache
if errorlevel 1 ( echo Core build failed. Aborting. & exit /b 1 )

echo.
echo === [prod-local-obs] Validating merged Compose configs ===
for %%P in ("%DATA_FILES%" "%MESSAGING_FILES%" "%AI_FILES%" "%OBS_FILES%" "%PLAT_FILES%" "%CORE_FILES%") do (
    docker compose --env-file "%ENV_FILE%" %%~P config --quiet
    if errorlevel 1 ( echo Compose config validation failed for %%~P. Aborting. & exit /b 1 )
)

call :up_project "data tier"           "%DATA_FILES%"      "postgres valkey"
if errorlevel 1 exit /b 1

echo.
echo === [prod-local-obs] Applying idempotent Postgres role/schema bootstrap ===
docker compose --env-file "%ENV_FILE%" %DATA_FILES% exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
if errorlevel 1 (
    echo Postgres bootstrap failed. Aborting.
    docker compose --env-file "%ENV_FILE%" %DATA_FILES% logs --tail=200 postgres
    exit /b 1
)

call :up_project "messaging tier"      "%MESSAGING_FILES%" "kafka"
if errorlevel 1 exit /b 1

call :up_project "AI runtime tier"     "%AI_FILES%"        "ollama"
if errorlevel 1 exit /b 1

call :up_project "observability tier"  "%OBS_FILES%"       "zipkin prometheus victorialogs alloy"
if errorlevel 1 exit /b 1

call :up_project "platform tier"       "%PLAT_FILES%"      "config-server discovery-server"
if errorlevel 1 exit /b 1

call :up_project "core: identity+edge" "%CORE_FILES%"      "account-service auth-service api-gateway"
if errorlevel 1 exit /b 1

call :up_project "core: workers"       "%CORE_FILES%"      "prompt-service gemini-service gpt-service local-ai-service"
if errorlevel 1 exit /b 1

call :up_project "core: orchestrator"  "%CORE_FILES%"      "orchestrator-service"
if errorlevel 1 exit /b 1

echo.
echo === [prod-local-obs] Waiting for api-gateway actuator health ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline = (Get-Date).AddMinutes(5); do { try { $health = Invoke-RestMethod -Uri 'http://localhost:8080/actuator/health' -TimeoutSec 5; if ($health.status -eq 'UP') { Write-Host 'api-gateway actuator health is UP'; exit 0 } } catch { Write-Host ('api-gateway health not ready: ' + $_.Exception.Message) }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline); exit 1"
if errorlevel 1 (
    echo ERROR: api-gateway did not become healthy.
    docker compose --env-file "%ENV_FILE%" %CORE_FILES% logs --tail=200 api-gateway
    exit /b 1
)

echo.
echo === [prod-local-obs] Stack is up.
echo === [prod-local-obs] Edge URL:        http://localhost:8080/actuator/health
echo === [prod-local-obs] Prometheus:      http://127.0.0.1:9090
echo === [prod-local-obs] Zipkin:          http://127.0.0.1:9411
echo === [prod-local-obs] VictoriaLogs UI: http://127.0.0.1:9428/select/vmui/
echo === [prod-local-obs] VictoriaLogs API health: http://127.0.0.1:9428/health
echo === [prod-local-obs] (No standalone dashboard — Perses fallback active; use the admin UI Error Events page.)
exit /b 0

REM ---------------------------------------------------------------------------
:check_docker_engine
docker info >NUL 2>&1
if errorlevel 1 (
    echo ERROR: Docker Engine is not reachable.
    for /f "delims=" %%C in ('docker context show 2^>NUL') do echo Active Docker context: %%C
    echo.
    echo Start Docker Desktop and wait until it reports that the Linux engine is running.
    echo Then verify with: docker info
    echo If Docker Desktop is already running, check: docker context ls
    echo Retry %~1.cmd after the Docker Engine is reachable.
    exit /b 1
)
exit /b 0

REM ---------------------------------------------------------------------------
:ensure_network
docker network inspect %~1 >NUL 2>&1
if errorlevel 1 (
    docker network create -d bridge %~1 >NUL
    if errorlevel 1 ( echo Failed to create network %~1. & exit /b 1 )
    echo Created network %~1.
) else (
    echo Network %~1 already exists.
)
exit /b 0

REM ---------------------------------------------------------------------------
:up_project
set "STAGE_NAME=%~1"
set "STAGE_FILES=%~2"
set "STAGE_SERVICES=%~3"

echo.
echo === [prod-local-obs] Starting %STAGE_NAME% (wait timeout: %WAIT_SECONDS%s) ===
docker compose --env-file "%ENV_FILE%" %STAGE_FILES% up -d --wait --wait-timeout %WAIT_SECONDS% %STAGE_SERVICES%
if errorlevel 1 (
    echo ERROR: %STAGE_NAME% failed to become ready.
    docker compose --env-file "%ENV_FILE%" %STAGE_FILES% ps %STAGE_SERVICES%
    docker compose --env-file "%ENV_FILE%" %STAGE_FILES% logs --tail=200 %STAGE_SERVICES%
    exit /b 1
)
echo === [prod-local-obs] %STAGE_NAME% ready ===
exit /b 0
