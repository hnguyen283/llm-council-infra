@echo off
REM ============================================================================
REM prod-overlays.cmd  --  Production stack with all local overlay conveniences.
REM
REM Starts every Compose project in the split-project production topology while
REM layering the overlays needed for local observability access and file logs:
REM   - projects/observability/overlays/local-observability.yml
REM   - projects/platform/overlays/log-files.yml
REM   - projects/core/overlays/log-files.yml
REM
REM This is intended for local production-like testing after the Compose split:
REM observability tools are published on the host loopback interface, and Spring
REM service logs are mounted to LOG_DIR_HOST so Alloy can ship them into VictoriaLogs.
REM ============================================================================

setlocal
cd /d "%~dp0"
set "ROOT=%~dp0..\..\"
set "ENV_FILE=%~dp0.env"
set "WAIT_SECONDS=300"

set "DATA_FILES=-f %ROOT%projects\data\docker-compose.yml"
set "MESSAGING_FILES=-f %ROOT%projects\messaging\docker-compose.yml"
set "AI_FILES=-f %ROOT%projects\ai-runtime\docker-compose.yml"
set "OBS_FILES=-f %ROOT%projects\observability\docker-compose.yml -f %ROOT%projects\observability\overlays\prod.yml -f %ROOT%projects\observability\overlays\local-observability.yml"
set "PLAT_FILES=-f %ROOT%projects\platform\docker-compose.yml -f %ROOT%projects\platform\overlays\prod.yml -f %ROOT%projects\platform\overlays\log-files.yml"
set "CORE_FILES=-f %ROOT%projects\core\docker-compose.yml -f %ROOT%projects\core\overlays\prod.yml -f %ROOT%projects\core\overlays\log-files.yml"
set "GRAPHRAG_FILES=-f %ROOT%projects\graphrag\docker-compose.yml"
set "LOCAL_OBS_FILES=-f %ROOT%projects\observability\docker-compose.local.yml"

if not defined LOG_DIR_HOST set "LOG_DIR_HOST=%ROOT%logs"

set "OBS_LINK_HOST=%OBSERVABILITY_HOST_BIND%"
if not defined OBS_LINK_HOST set "OBS_LINK_HOST=127.0.0.1"
if "%OBS_LINK_HOST%"=="0.0.0.0" set "OBS_LINK_HOST=127.0.0.1"
REM Dashboard URL intentionally left empty — Perses skipped per the
REM approved P1.6 fallback (02 §3.4); app-native dashboard deferred to P2/P3.
if not defined ADMIN_OBS_UI_PROMETHEUS set "ADMIN_OBS_UI_PROMETHEUS=http://%OBS_LINK_HOST%:9090"
if not defined ADMIN_OBS_UI_ZIPKIN set "ADMIN_OBS_UI_ZIPKIN=http://%OBS_LINK_HOST%:9411"
if not defined ADMIN_OBS_UI_LOGS set "ADMIN_OBS_UI_LOGS=http://%OBS_LINK_HOST%:9428"
if not defined ADMIN_DASHBOARD_BASE_URL set "ADMIN_DASHBOARD_BASE_URL=/admin/observability"

call :main
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%

:main
echo.
echo === [prod-overlays] Checking Docker Compose availability ===
docker compose version
if errorlevel 1 (
    echo Docker Compose is not available. Aborting.
    exit /b 1
)
call :check_docker_engine "prod-overlays"
if errorlevel 1 exit /b 1

if not exist "%ENV_FILE%" (
    echo ERROR: .env was not found at "%ENV_FILE%"
    exit /b 1
)

if not exist "%LOG_DIR_HOST%" (
    mkdir "%LOG_DIR_HOST%"
    if errorlevel 1 (
        echo Failed to create LOG_DIR_HOST "%LOG_DIR_HOST%".
        exit /b 1
    )
)

echo.
echo === [prod-overlays] Active overlays ===
echo Observability: local-observability
echo Platform:      prod + log-files
echo Core:          prod + log-files
echo Host logs:     %LOG_DIR_HOST%

echo.
echo === [prod-overlays] Verifying required secrets are present in .env ===
for %%V in (AUTH_JWT_PRIVATE_KEY_PEM AUTH_JWT_PUBLIC_KEYS_PEM GATEWAY_INTERNAL_PRIVATE_KEY_PEM GATEWAY_INTERNAL_PUBLIC_KEYS_PEM POSTGRES_PASSWORD ACCOUNT_DB_PASSWORD PROMPT_DB_PASSWORD VALKEY_PASSWORD ACCOUNT_INTERNAL_SERVICE_TOKEN TENANT_NAMESPACE_HMAC_KEY) do (
    findstr /B /R /C:"%%V=." "%ENV_FILE%" >NUL 2>&1
    if errorlevel 1 (
        echo ERROR: %%V is empty or missing from .env
        exit /b 1
    )
)

echo.
echo === [prod-overlays] Ensuring external Docker networks exist ===
call :ensure_network llm-council-data
call :ensure_network llm-council-messaging
call :ensure_network llm-council-observability
call :ensure_network llm-council-platform
call :ensure_network llm-council-app
call :ensure_network llm-council-ai-runtime

echo.
echo === [prod-overlays] Packaging service JARs from current source ===
pushd "%ROOT%..\llm-council"
call mvn -DskipTests package
if errorlevel 1 ( popd & echo Maven package failed. Aborting. & exit /b 1 )
popd
if errorlevel 1 ( echo Maven package failed. Aborting. & exit /b 1 )

echo.
echo === [prod-overlays] Tearing down existing projects (reverse order) ===
docker compose --env-file "%ENV_FILE%" %CORE_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %PLAT_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %OBS_FILES%       down --remove-orphans
docker compose --env-file "%ENV_FILE%" %LOCAL_OBS_FILES% down --remove-orphans
docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES%  down --remove-orphans
docker compose --env-file "%ENV_FILE%" %AI_FILES%        down --remove-orphans
docker compose --env-file "%ENV_FILE%" %MESSAGING_FILES% down --remove-orphans
docker compose --env-file "%ENV_FILE%" %DATA_FILES%      down --remove-orphans

echo.
echo === [prod-overlays] Rebuilding project images (no cache) ===
docker compose --env-file "%ENV_FILE%" %PLAT_FILES% build --no-cache
if errorlevel 1 ( echo Platform build failed. Aborting. & exit /b 1 )
docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES% build --no-cache
if errorlevel 1 ( echo Graph-RAG build failed. Aborting. & exit /b 1 )
docker compose --env-file "%ENV_FILE%" %CORE_FILES% build --no-cache
if errorlevel 1 ( echo Core build failed. Aborting. & exit /b 1 )

echo.
echo === [prod-overlays] Validating merged Compose configs ===
for %%P in ("%DATA_FILES%" "%MESSAGING_FILES%" "%GRAPHRAG_FILES%" "%AI_FILES%" "%LOCAL_OBS_FILES%" "%OBS_FILES%" "%PLAT_FILES%" "%CORE_FILES%") do (
    docker compose --env-file "%ENV_FILE%" %%~P config --quiet
    if errorlevel 1 ( echo Compose config validation failed for %%~P. Aborting. & exit /b 1 )
)

call :up_project "data tier"           "%DATA_FILES%"      "postgres valkey"
if errorlevel 1 exit /b 1

echo.
echo === [prod-overlays] Applying idempotent Postgres role/schema bootstrap ===
docker compose --env-file "%ENV_FILE%" %DATA_FILES% exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
if errorlevel 1 (
    echo Postgres bootstrap failed. Aborting.
    docker compose --env-file "%ENV_FILE%" %DATA_FILES% logs --tail=200 postgres
    exit /b 1
)

call :up_project "messaging tier"      "%MESSAGING_FILES%" "kafka"
if errorlevel 1 exit /b 1

call :up_project "graphrag tier"       "%GRAPHRAG_FILES%"  "graphrag-retrieval-service graphrag-indexing-worker"
if errorlevel 1 exit /b 1

call :up_project "AI runtime tier"     "%AI_FILES%"        "ollama"
if errorlevel 1 exit /b 1

call :up_project "observability tier"  "%OBS_FILES%"       "zipkin prometheus victorialogs alloy"
if errorlevel 1 exit /b 1

call :up_project "local observability"  "%LOCAL_OBS_FILES%" "age-viewer arize-phoenix"
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
echo === [prod-overlays] Waiting for api-gateway actuator health ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline = (Get-Date).AddMinutes(5); do { try { $health = Invoke-RestMethod -Uri 'http://localhost:8080/actuator/health' -TimeoutSec 5; if ($health.status -eq 'UP') { Write-Host 'api-gateway actuator health is UP'; exit 0 } } catch { Write-Host ('api-gateway health not ready: ' + $_.Exception.Message) }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline); exit 1"
if errorlevel 1 (
    echo ERROR: api-gateway did not become healthy.
    docker compose --env-file "%ENV_FILE%" %CORE_FILES% logs --tail=200 api-gateway
    exit /b 1
)

echo.
echo === [prod-overlays] Stack is up.
echo === [prod-overlays] Edge URL:         http://localhost:8080/actuator/health
echo === [prod-overlays] Prometheus:       %ADMIN_OBS_UI_PROMETHEUS%
echo === [prod-overlays] Zipkin:           %ADMIN_OBS_UI_ZIPKIN%
echo === [prod-overlays] VictoriaLogs UI:  %ADMIN_OBS_UI_LOGS%/select/vmui/
echo === [prod-overlays] VictoriaLogs API: %ADMIN_OBS_UI_LOGS%/health
echo === [prod-overlays] (No standalone dashboard — Perses fallback active; use the admin UI Error Events page.)
echo === [prod-overlays] Host logs:        %LOG_DIR_HOST%
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
echo === [prod-overlays] Starting %STAGE_NAME% (wait timeout: %WAIT_SECONDS%s) ===
docker compose --env-file "%ENV_FILE%" %STAGE_FILES% up -d --wait --wait-timeout %WAIT_SECONDS% %STAGE_SERVICES%
if errorlevel 1 (
    echo ERROR: %STAGE_NAME% failed to become ready.
    docker compose --env-file "%ENV_FILE%" %STAGE_FILES% ps %STAGE_SERVICES%
    docker compose --env-file "%ENV_FILE%" %STAGE_FILES% logs --tail=200 %STAGE_SERVICES%
    exit /b 1
)
echo === [prod-overlays] %STAGE_NAME% ready ===
exit /b 0
