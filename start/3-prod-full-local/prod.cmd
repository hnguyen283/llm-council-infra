@echo off
REM ============================================================================
REM prod.cmd  --  Bring up the FULL stack across six independent Compose
REM               projects with tier-segregated external networks.
REM
REM Projects (in startup order):
REM   llm-council-data           (postgres, valkey)
REM   llm-council-messaging      (kafka — apache/kafka KRaft, no Zookeeper)
REM   llm-council-ai-runtime     (ollama)
REM   llm-council-observability  (zipkin, prometheus, victorialogs, alloy)
REM   llm-council-platform       (config-server, discovery-server)
REM   llm-council-core           (api-gateway + 7 Spring application services)
REM
REM Networks (created idempotently at the top of this script):
REM   llm-council-data           data tier
REM   llm-council-messaging      kafka tier
REM   llm-council-observability  zipkin/prometheus/victorialogs/alloy
REM   llm-council-platform       config-server + discovery-server
REM   llm-council-app            inter-service application traffic + prom scrape
REM   llm-council-ai-runtime     ollama
REM
REM Restrictive posture:
REM   - Only api-gateway (8080) is published to the host.
REM   - Postgres, Valkey, Kafka, observability portals, Spring HTTP ports,
REM     config-server, discovery-server, Ollama, and JDWP are unpublished.
REM   - JAVA_TOOL_OPTIONS strips the JDWP agent.
REM
REM For loopback observability access, use prod-local-obs.cmd.
REM ============================================================================

setlocal
cd /d "%~dp0"
set "ROOT=%~dp0..\..\"
set "ENV_FILE=%~dp0.env"
set "WAIT_SECONDS=300"

REM ---- Per-project file chains -------------------------------------------------
set "DATA_FILES=-f %ROOT%projects\data\docker-compose.yml"
set "MESSAGING_FILES=-f %ROOT%projects\messaging\docker-compose.yml"
set "AI_FILES=-f %ROOT%projects\ai-runtime\docker-compose.yml"
set "OBS_FILES=-f %ROOT%projects\observability\docker-compose.yml -f %ROOT%projects\observability\overlays\prod.yml"
set "PLAT_FILES=-f %ROOT%projects\platform\docker-compose.yml -f %ROOT%projects\platform\overlays\prod.yml"
set "CORE_FILES=-f %ROOT%projects\core\docker-compose.yml -f %ROOT%projects\core\overlays\prod.yml"
set "GRAPHRAG_FILES=-f %ROOT%projects\graphrag\docker-compose.yml"

call :main
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%

:main
echo.
echo === [prod] Checking Docker Compose availability ===
docker compose version
if errorlevel 1 (
    echo Docker Compose is not available. Aborting.
    exit /b 1
)
call :check_docker_engine "prod"
if errorlevel 1 exit /b 1

echo.
echo === [prod] Verifying required secrets are present in .env ===
for %%V in (AUTH_JWT_PRIVATE_KEY_PEM AUTH_JWT_PUBLIC_KEYS_PEM GATEWAY_INTERNAL_PRIVATE_KEY_PEM GATEWAY_INTERNAL_PUBLIC_KEYS_PEM POSTGRES_PASSWORD ACCOUNT_DB_PASSWORD PROMPT_DB_PASSWORD VALKEY_PASSWORD ACCOUNT_INTERNAL_SERVICE_TOKEN TENANT_NAMESPACE_HMAC_KEY) do (
    findstr /B /R /C:"%%V=." "%ENV_FILE%" >NUL 2>&1
    if errorlevel 1 (
        echo ERROR: %%V is empty or missing from .env
        echo See .env.example for the required values and openssl commands.
        exit /b 1
    )
)

echo.
echo === [prod] Validating Graph-RAG Mode and Alias ===
set "GRAPHRAG_MODE="
set "GRAPHRAG_ENABLED="

if exist "%ENV_FILE%" (
    for /f "usebackq tokens=1,2 delims==" %%A in ("%ENV_FILE%") do (
        if "%%A"=="GRAPHRAG_MODE" set "GRAPHRAG_MODE=%%~B"
        if "%%A"=="GRAPHRAG_ENABLED" set "GRAPHRAG_ENABLED=%%~B"
    )
)

if "%GRAPHRAG_MODE%"=="" (
    if "%GRAPHRAG_ENABLED%"=="true" (
        set "GRAPHRAG_MODE=optional"
    ) else if "%GRAPHRAG_ENABLED%"=="false" (
        set "GRAPHRAG_MODE=disabled"
    ) else (
        set "GRAPHRAG_MODE=disabled"
    )
)

if NOT "%GRAPHRAG_MODE%"=="disabled" if NOT "%GRAPHRAG_MODE%"=="optional" if NOT "%GRAPHRAG_MODE%"=="required" (
    echo ERROR: Invalid GRAPHRAG_MODE '%GRAPHRAG_MODE%'. Must be one of: disabled, optional, required.
    exit /b 1
)

echo Graph-RAG mode validated: GRAPHRAG_MODE=%GRAPHRAG_MODE%

if "%GRAPHRAG_MODE%"=="disabled" (
    set "GRAPHRAG_ENABLED=false"
) else (
    findstr /B /R /C:"GRAPHRAG_DB_PASSWORD=." "%ENV_FILE%" >NUL 2>&1
    if errorlevel 1 (
        echo ERROR: GRAPHRAG_DB_PASSWORD is empty or missing from .env while Graph-RAG is %GRAPHRAG_MODE%.
        exit /b 1
    )
    set "GRAPHRAG_ENABLED=true"
)

echo.
echo === [prod] Ensuring external Docker networks exist ===
call :ensure_network llm-council-data
call :ensure_network llm-council-messaging
call :ensure_network llm-council-observability
call :ensure_network llm-council-platform
call :ensure_network llm-council-app
call :ensure_network llm-council-ai-runtime

echo.
echo === [prod] Packaging service JARs from current source ===
pushd "%ROOT%..\llm-council"
call mvn -DskipTests package
if errorlevel 1 ( popd & echo Maven package failed. Aborting. & exit /b 1 )
popd
if errorlevel 1 (
    echo Maven package failed. Aborting.
    exit /b 1
)

echo.
echo === [prod] Tearing down existing projects (reverse order) ===
docker compose --env-file "%ENV_FILE%" %CORE_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %PLAT_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %OBS_FILES%       down --remove-orphans
docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES%  down --remove-orphans
docker compose --env-file "%ENV_FILE%" %AI_FILES%        down --remove-orphans
docker compose --env-file "%ENV_FILE%" %MESSAGING_FILES% down --remove-orphans
docker compose --env-file "%ENV_FILE%" %DATA_FILES%      down --remove-orphans

echo.
echo === [prod] Rebuilding project images (no cache) ===
docker compose --env-file "%ENV_FILE%" %PLAT_FILES% build --no-cache
if errorlevel 1 ( echo Platform build failed. Aborting. & exit /b 1 )
docker compose --env-file "%ENV_FILE%" %CORE_FILES% build --no-cache
if errorlevel 1 ( echo Core build failed. Aborting. & exit /b 1 )

if NOT "%GRAPHRAG_MODE%"=="disabled" (
    echo === [prod] Rebuilding Graph-RAG images (no cache) ===
    docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES% build --no-cache
    if errorlevel 1 ( echo Graph-RAG build failed. Aborting. & exit /b 1 )
)

echo.
echo === [prod] Validating merged Compose configs (each project) ===
for %%P in ("%DATA_FILES%" "%MESSAGING_FILES%" "%AI_FILES%" "%OBS_FILES%" "%PLAT_FILES%" "%CORE_FILES%") do (
    docker compose --env-file "%ENV_FILE%" %%~P config --quiet
    if errorlevel 1 (
        echo Compose config validation failed for %%~P. Aborting.
        exit /b 1
    )
)
if NOT "%GRAPHRAG_MODE%"=="disabled" (
    docker compose --env-file "%ENV_FILE%" %GRAPHRAG_FILES% config --quiet
    if errorlevel 1 (
        echo Compose config validation failed for Graph-RAG. Aborting.
        exit /b 1
    )
)

call :up_project "data tier"          "%DATA_FILES%"      "postgres valkey"
if errorlevel 1 exit /b 1

echo.
echo === [prod] Applying idempotent Postgres role/schema bootstrap ===
docker compose --env-file "%ENV_FILE%" %DATA_FILES% exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
if errorlevel 1 (
    echo Postgres bootstrap failed. Aborting.
    docker compose --env-file "%ENV_FILE%" %DATA_FILES% logs --tail=200 postgres
    exit /b 1
)

call :up_project "messaging tier"     "%MESSAGING_FILES%" "kafka"
if errorlevel 1 exit /b 1

call :up_project "AI runtime tier"    "%AI_FILES%"        "ollama"
if errorlevel 1 exit /b 1

call :up_project "observability tier" "%OBS_FILES%"       "zipkin prometheus victorialogs alloy"
if errorlevel 1 exit /b 1

call :up_project "platform tier"      "%PLAT_FILES%"      "config-server discovery-server"
if errorlevel 1 exit /b 1

if NOT "%GRAPHRAG_MODE%"=="disabled" (
    call :up_project "graphrag tier" "%GRAPHRAG_FILES%" "graphrag-retrieval-service graphrag-indexing-worker"
    if errorlevel 1 (
        if "%GRAPHRAG_MODE%"=="required" (
            echo ERROR: Graph-RAG tier failed to start or is unhealthy, and mode is required. Aborting.
            exit /b 1
        ) else (
            echo WARNING: Graph-RAG tier failed to start or is unhealthy, but mode is optional. Continuing...
            set "GRAPHRAG_ENABLED=false"
        )
    )
)

call :up_project "core: identity+edge" "%CORE_FILES%"     "account-service auth-service api-gateway"
if errorlevel 1 exit /b 1

call :up_project "core: workers"       "%CORE_FILES%"     "prompt-service gemini-service gpt-service local-ai-service"
if errorlevel 1 exit /b 1

call :up_project "core: orchestrator"  "%CORE_FILES%"     "orchestrator-service"
if errorlevel 1 exit /b 1

echo.
echo === [prod] Waiting for api-gateway actuator health ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline = (Get-Date).AddMinutes(5); do { try { $health = Invoke-RestMethod -Uri 'http://localhost:8080/actuator/health' -TimeoutSec 5; if ($health.status -eq 'UP') { Write-Host 'api-gateway actuator health is UP'; exit 0 }; Write-Host ('api-gateway health status: ' + $health.status) } catch { Write-Host ('api-gateway health not ready: ' + $_.Exception.Message) }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline); exit 1"
if errorlevel 1 (
    echo ERROR: api-gateway did not become healthy at http://localhost:8080/actuator/health
    docker compose --env-file "%ENV_FILE%" %CORE_FILES% ps api-gateway
    docker compose --env-file "%ENV_FILE%" %CORE_FILES% logs --tail=200 api-gateway
    exit /b 1
)

echo.
echo === [prod] Stack is up. Edge URL: http://localhost:8080/actuator/health
echo === [prod] Tail logs:    docker compose --env-file "%ENV_FILE%" %CORE_FILES% logs -f
echo === [prod] Stop all:     prod-down.cmd  (or run `docker compose down` per project)
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
    if errorlevel 1 (
        echo Failed to create network %~1.
        exit /b 1
    )
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
echo === [prod] Starting %STAGE_NAME% (wait timeout: %WAIT_SECONDS%s) ===
docker compose --env-file "%ENV_FILE%" %STAGE_FILES% up -d --wait --wait-timeout %WAIT_SECONDS% %STAGE_SERVICES%
if errorlevel 1 (
    echo ERROR: %STAGE_NAME% failed to become ready.
    echo Services: %STAGE_SERVICES%
    docker compose --env-file "%ENV_FILE%" %STAGE_FILES% ps %STAGE_SERVICES%
    docker compose --env-file "%ENV_FILE%" %STAGE_FILES% logs --tail=200 %STAGE_SERVICES%
    exit /b 1
)

echo === [prod] %STAGE_NAME% ready ===
exit /b 0
