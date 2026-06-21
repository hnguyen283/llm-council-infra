@echo off
REM ============================================================================
REM prod-lite.cmd -- Experimental hybrid VPS startup.
REM
REM VPS services:
REM   data, messaging, platform, api/auth/account/orchestrator/prompt,
REM   gemini-service, and gpt-service.
REM
REM Laptop services:
REM   Ollama + local-ai-service (remote-worker profile).
REM
REM This keeps public prompt processing available when the laptop is off while
REM treating local AI as an optional quality enhancement.
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
set "OBS_FILES=-f %OBS_DIR%\docker-compose.yml -f %OBS_DIR%\overlays\prod.yml"

set "PLAT_DIR=projects\platform"
set "PLAT_FILES=-f %PLAT_DIR%\docker-compose.yml -f %PLAT_DIR%\overlays\prod.yml"

set "CORE_DIR=projects\core"
set "CORE_FILES=-f %CORE_DIR%\docker-compose.yml -f %CORE_DIR%\overlays\prod.yml -f %CORE_DIR%\overlays\prod-lite.yml"

call :main
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%

:main
echo.
echo === [prod-lite] Checking Docker Compose availability ===
docker compose version
if errorlevel 1 (
    echo Docker Compose is not available. Aborting.
    exit /b 1
)
call :check_docker_engine "prod-lite"
if errorlevel 1 exit /b 1

echo.
echo === [prod-lite] Verifying required secrets are present in .env ===
for %%V in (AUTH_JWT_PRIVATE_KEY_PEM AUTH_JWT_PUBLIC_KEYS_PEM GATEWAY_INTERNAL_PRIVATE_KEY_PEM GATEWAY_INTERNAL_PUBLIC_KEYS_PEM POSTGRES_PASSWORD ACCOUNT_DB_PASSWORD PROMPT_DB_PASSWORD VALKEY_PASSWORD ACCOUNT_INTERNAL_SERVICE_TOKEN) do (
    findstr /B /R /C:"%%V=." .env >NUL 2>&1
    if errorlevel 1 (
        echo ERROR: %%V is empty or missing from .env
        echo See .env.example for the required values and openssl commands.
        exit /b 1
    )
)

echo.
echo === [prod-lite] Ensuring external Docker networks exist ===
call :ensure_network llm-council-data
call :ensure_network llm-council-messaging
call :ensure_network llm-council-observability
call :ensure_network llm-council-platform
call :ensure_network llm-council-app
call :ensure_network llm-council-ai-runtime

echo.
echo === [prod-lite] Packaging service JARs from current source ===
pushd "%ROOT%..\llm-council"
call mvn -DskipTests package
if errorlevel 1 ( popd & echo Maven package failed. Aborting. & exit /b 1 )
popd
if errorlevel 1 (
    echo Maven package failed. Aborting.
    exit /b 1
)

echo.
echo === [prod-lite] Tearing down omitted/full-stack projects ===
docker compose --env-file "%ENV_FILE%" %CORE_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %PLAT_FILES%      down --remove-orphans
docker compose --env-file "%ENV_FILE%" %OBS_FILES%       down --remove-orphans
docker compose --env-file "%ENV_FILE%" %AI_FILES%        down --remove-orphans
docker compose --env-file "%ENV_FILE%" %MESSAGING_FILES% down --remove-orphans
docker compose --env-file "%ENV_FILE%" %DATA_FILES%      down --remove-orphans

echo.
echo === [prod-lite] Rebuilding required project images (no cache) ===
docker compose --env-file "%ENV_FILE%" %PLAT_FILES% build --no-cache
if errorlevel 1 ( echo Platform build failed. Aborting. & exit /b 1 )
docker compose --env-file "%ENV_FILE%" %CORE_FILES% build --no-cache api-gateway auth-service account-service orchestrator-service prompt-service gemini-service gpt-service
if errorlevel 1 ( echo Core build failed. Aborting. & exit /b 1 )

echo.
echo === [prod-lite] Validating merged Compose configs ===
for %%P in ("%DATA_FILES%" "%MESSAGING_FILES%" "%PLAT_FILES%" "%CORE_FILES%") do (
    docker compose --env-file "%ENV_FILE%" %%~P config --quiet
    if errorlevel 1 (
        echo Compose config validation failed for %%~P. Aborting.
        exit /b 1
    )
)

call :up_project "data tier"          "%DATA_FILES%"      "postgres valkey"
if errorlevel 1 exit /b 1

echo.
echo === [prod-lite] Applying idempotent Postgres role/schema bootstrap ===
docker compose --env-file "%ENV_FILE%" %DATA_FILES% exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
if errorlevel 1 (
    echo Postgres bootstrap failed. Aborting.
    docker compose --env-file "%ENV_FILE%" %DATA_FILES% logs --tail=200 postgres
    exit /b 1
)

call :up_project "messaging tier"     "%MESSAGING_FILES%" "kafka"
if errorlevel 1 exit /b 1

call :up_project "platform tier"      "%PLAT_FILES%"      "config-server discovery-server"
if errorlevel 1 exit /b 1

call :up_project "core: identity+edge" "%CORE_FILES%"     "account-service auth-service api-gateway"
if errorlevel 1 exit /b 1

call :up_project "core: fallback AI workers" "%CORE_FILES%" "prompt-service gemini-service gpt-service"
if errorlevel 1 exit /b 1

call :up_project "core: orchestrator" "%CORE_FILES%"      "orchestrator-service"
if errorlevel 1 exit /b 1

echo.
echo === [prod-lite] Waiting for api-gateway actuator health ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline = (Get-Date).AddMinutes(5); do { try { $health = Invoke-RestMethod -Uri 'http://localhost:8080/actuator/health' -TimeoutSec 5; if ($health.status -eq 'UP') { Write-Host 'api-gateway actuator health is UP'; exit 0 }; Write-Host ('api-gateway health status: ' + $health.status) } catch { Write-Host ('api-gateway health not ready: ' + $_.Exception.Message) }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline); exit 1"
if errorlevel 1 (
    echo ERROR: api-gateway did not become healthy at http://localhost:8080/actuator/health
    docker compose --env-file "%ENV_FILE%" %CORE_FILES% ps api-gateway
    docker compose --env-file "%ENV_FILE%" %CORE_FILES% logs --tail=200 api-gateway
    exit /b 1
)

echo.
echo === [prod-lite] Stack is up. Edge URL: http://localhost:8080/actuator/health
echo === [prod-lite] Local AI is optional; start laptop local-ai-service with SPRING_PROFILES_ACTIVE=remote-worker.
exit /b 0

:check_docker_engine
docker info >NUL 2>&1
if errorlevel 1 (
    echo ERROR: Docker Engine is not reachable.
    for /f "delims=" %%C in ('docker context show 2^>NUL') do echo Active Docker context: %%C
    echo Start Docker Desktop and wait until the Linux engine is running.
    exit /b 1
)
exit /b 0

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

:up_project
set "STAGE_NAME=%~1"
set "STAGE_FILES=%~2"
set "STAGE_SERVICES=%~3"

echo.
echo === [prod-lite] Starting %STAGE_NAME% (wait timeout: %WAIT_SECONDS%s) ===
docker compose --env-file "%ENV_FILE%" %STAGE_FILES% up -d --wait --wait-timeout %WAIT_SECONDS% %STAGE_SERVICES%
if errorlevel 1 (
    echo ERROR: %STAGE_NAME% failed to become ready.
    echo Services: %STAGE_SERVICES%
    docker compose --env-file "%ENV_FILE%" %STAGE_FILES% ps %STAGE_SERVICES%
    docker compose --env-file "%ENV_FILE%" %STAGE_FILES% logs --tail=200 %STAGE_SERVICES%
    exit /b 1
)

echo === [prod-lite] %STAGE_NAME% ready ===
exit /b 0
