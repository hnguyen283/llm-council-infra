@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0.."
if "%~1"=="" (
  set "OPTION=prod-full-local-http"
) else (
  set "OPTION=%~1"
)
set "DRY_RUN=false"
if /I "%~2"=="--dry-run" set "DRY_RUN=true"
set "START_WAIT_TIMEOUT_SECONDS=%START_WAIT_TIMEOUT_SECONDS%"
if not defined START_WAIT_TIMEOUT_SECONDS set "START_WAIT_TIMEOUT_SECONDS=600"

set "OPTION_DIR=%ROOT%\options\%OPTION%"
if not exist "%OPTION_DIR%\option.env" (
  echo ERROR: Unknown option "%OPTION%".
  echo Available options:
  for /d %%D in ("%ROOT%\options\*") do echo   %%~nxD
  exit /b 1
)
if not exist "%OPTION_DIR%\compose.files" (
  echo ERROR: "%OPTION%" is not a local Compose start option.
  echo See %OPTION_DIR%\README.md for the correct command.
  exit /b 1
)

set "OPTION_KIND=compose-stack"
set "LOCAL_AI_PREPARE_MODEL=false"
set "LOCAL_AI_BASE_MODEL=deepseek-r1:7b"
set "LOCAL_AI_MODEL=planner"
for /f "usebackq tokens=1,* delims==" %%A in ("%OPTION_DIR%\option.env") do (
  if /I "%%A"=="OPTION_KIND" set "OPTION_KIND=%%B"
  if /I "%%A"=="LOCAL_AI_PREPARE_MODEL" set "LOCAL_AI_PREPARE_MODEL=%%B"
  if /I "%%A"=="LOCAL_AI_BASE_MODEL" set "LOCAL_AI_BASE_MODEL=%%B"
  if /I "%%A"=="LOCAL_AI_MODEL" set "LOCAL_AI_MODEL=%%B"
)

echo === [start] Validating semantic option: %OPTION% ===
call "%ROOT%\scripts\config.bat" "%OPTION%"
if errorlevel 1 exit /b 1

set "GENERATED_DIR=%ROOT%\.generated\%OPTION%"
if /I "%DRY_RUN%"=="true" (
  echo Dry run complete. Safe diagnostics: %GENERATED_DIR%
  exit /b 0
)

set "RUNTIME_ENV_ARGS="
for /f "usebackq tokens=* delims=" %%L in ("%ROOT%\.generated\%OPTION%\environment.layers.txt") do if not "%%L"=="" set "RUNTIME_ENV_ARGS=!RUNTIME_ENV_ARGS! --env-file "%ROOT%\%%L""
set "RUNTIME_FILE_ARGS="
for /f "usebackq tokens=* delims=" %%L in ("%ROOT%\.generated\%OPTION%\compose.files.txt") do if not "%%L"=="" set "RUNTIME_FILE_ARGS=!RUNTIME_FILE_ARGS! -f "%ROOT%\%%L""
set "RUNTIME_PROFILE_ARGS="
for /f "usebackq tokens=* delims=" %%P in ("%ROOT%\.generated\%OPTION%\profiles.txt") do if not "%%P"=="" set "RUNTIME_PROFILE_ARGS=!RUNTIME_PROFILE_ARGS! --profile %%P"

call :pin_docker_api_version
if errorlevel 1 exit /b 1

call :ensure_network llm-council-data
call :ensure_network llm-council-messaging
call :ensure_network llm-council-observability
call :ensure_network llm-council-platform
call :ensure_network llm-council-app
call :ensure_network llm-council-ai-runtime

echo.
if /I not "%OPTION_KIND%"=="local-ai-runtime" (
  echo === [start] Packaging Spring service JARs ===
  pushd "%ROOT%\..\llm-council"
  call mvn -DskipTests package
  if errorlevel 1 ( popd & echo Maven package failed. Aborting. & exit /b 1 )
  popd
) else (
  echo === [start] Skipping Spring package for local AI runtime option ===
)

echo.
set "HAS_POSTGRES="
for /f "delims=" %%S in ('docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! config --services') do (
  if /I "%%S"=="postgres" set "HAS_POSTGRES=true"
)
if defined HAS_POSTGRES (
  echo === [start] Starting Postgres before database clients ===
  docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! up -d --build --wait --wait-timeout %START_WAIT_TIMEOUT_SECONDS% postgres
  if errorlevel 1 (
    call :dump_start_failure
    exit /b 1
  )

  echo.
  echo === [start] Reconciling Postgres roles with current environment ===
  docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
  if errorlevel 1 exit /b 1
)

echo.
echo === [start] Starting %OPTION% from the validated semantic Compose files ===
docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! up -d --build --wait --wait-timeout %START_WAIT_TIMEOUT_SECONDS%
if errorlevel 1 (
  call :dump_start_failure
  exit /b 1
)

if /I "%LOCAL_AI_PREPARE_MODEL%"=="true" (
  echo.
  echo === [start] Preparing Ollama model %LOCAL_AI_BASE_MODEL% and alias %LOCAL_AI_MODEL% ===
  docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! exec ollama ollama pull "%LOCAL_AI_BASE_MODEL%"
  if errorlevel 1 exit /b 1
  docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! exec ollama ollama create "%LOCAL_AI_MODEL%" -f /Modelfile.planner
  if errorlevel 1 exit /b 1
)

echo.
echo === [start] %OPTION% is up ===
echo Public origin is recorded in %ROOT%\.generated\%OPTION%\environment.resolved.txt
exit /b 0

:ensure_network
docker network inspect %~1 >NUL 2>&1
if errorlevel 1 (
  docker network create -d bridge %~1 >NUL
  if errorlevel 1 exit /b 1
  echo Created network %~1.
) else (
  echo Network %~1 already exists.
)
exit /b 0

:dump_start_failure
echo.
echo === [start] Startup failed; targeted diagnostics follow ===
echo Compose services:
docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! ps
for %%S in (api-gateway auth-service account-service config-server discovery-server valkey postgres) do (
  echo.
  echo --- %%S status ---
  docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! ps %%S
  echo --- %%S logs ^(tail 160^) ---
  docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! logs --tail=160 %%S
)
set "GATEWAY_CONTAINER="
for /f "delims=" %%C in ('docker compose !RUNTIME_ENV_ARGS! !RUNTIME_FILE_ARGS! !RUNTIME_PROFILE_ARGS! ps -q api-gateway 2^>NUL') do set "GATEWAY_CONTAINER=%%C"
if defined GATEWAY_CONTAINER (
  echo.
  echo --- api-gateway Docker health state ---
  docker inspect "%GATEWAY_CONTAINER%" --format "{{json .State.Health}}"
)
exit /b 0

:pin_docker_api_version
set "ORIGINAL_DOCKER_API_VERSION=%DOCKER_API_VERSION%"
set "ORIGINAL_DOCKER_HOST=%DOCKER_HOST%"
set "SERVER_DOCKER_API_VERSION="
set "PINNED_DOCKER_API_VERSION="

call :probe_docker_api_versions
if not errorlevel 1 goto docker_api_pinned

if not defined ORIGINAL_DOCKER_HOST (
  set "DOCKER_HOST=npipe:////./pipe/docker_engine"
  set "SERVER_DOCKER_API_VERSION="
  set "PINNED_DOCKER_API_VERSION="
  call :probe_docker_api_versions
  if not errorlevel 1 (
    echo Docker context pipe failed; using Docker Desktop fallback pipe npipe:////./pipe/docker_engine
    goto docker_api_pinned
  )
  set "DOCKER_HOST="
)

:docker_api_pinned
if defined PINNED_DOCKER_API_VERSION (
  set "DOCKER_API_VERSION=%PINNED_DOCKER_API_VERSION%"
  echo Docker Engine API version pinned to %PINNED_DOCKER_API_VERSION% ^(server reports %SERVER_DOCKER_API_VERSION%^)
  exit /b 0
)

if defined ORIGINAL_DOCKER_API_VERSION set "DOCKER_API_VERSION=%ORIGINAL_DOCKER_API_VERSION%"
if defined ORIGINAL_DOCKER_HOST set "DOCKER_HOST=%ORIGINAL_DOCKER_HOST%"
echo ERROR: Docker Engine is not reachable or API negotiation failed.
echo This is a Docker Desktop engine/proxy problem if /version returns HTTP 500.
echo Run: scripts\docker-diagnose.bat
echo Then restart Docker Desktop and run: wsl --shutdown
exit /b 1

:probe_docker_api_versions
for %%A in (1.53 1.52 1.51 1.50 1.49 1.48 1.47 1.46 1.45 1.44 1.43 1.42 1.41) do (
  set "DOCKER_API_VERSION=%%A"
  for /f "delims=" %%V in ('docker version --format "{{.Server.APIVersion}}" 2^>NUL') do set "SERVER_DOCKER_API_VERSION=%%V"
  if defined SERVER_DOCKER_API_VERSION (
    set "PINNED_DOCKER_API_VERSION=%%A"
    exit /b 0
  )
)
exit /b 1
