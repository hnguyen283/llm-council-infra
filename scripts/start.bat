@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
if "%~1"=="" (
  set "OPTION=prod-full-local-http"
) else (
  set "OPTION=%~1"
)
set "DRY_RUN=false"
if /I "%~2"=="--dry-run" set "DRY_RUN=true"

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

set "GENERATED=%ROOT%\.generated\%OPTION%\compose.resolved.yaml"
if /I "%DRY_RUN%"=="true" (
  echo Dry run complete. Rendered config: %GENERATED%
  exit /b 0
)

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
echo === [start] Starting %OPTION% from rendered Compose config ===
docker compose -f "%GENERATED%" up -d --build --wait --wait-timeout 300
if errorlevel 1 exit /b 1

docker compose -f "%GENERATED%" ps postgres >NUL 2>&1
if not errorlevel 1 (
  echo.
  echo === [start] Applying idempotent Postgres bootstrap ===
  docker compose -f "%GENERATED%" exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
  if errorlevel 1 exit /b 1
)

if /I "%OPTION_KIND%"=="local-ai-runtime" if /I "%LOCAL_AI_PREPARE_MODEL%"=="true" (
  echo.
  echo === [start] Preparing Ollama model %LOCAL_AI_BASE_MODEL% and alias %LOCAL_AI_MODEL% ===
  docker compose -f "%GENERATED%" exec ollama ollama pull "%LOCAL_AI_BASE_MODEL%"
  if errorlevel 1 exit /b 1
  docker compose -f "%GENERATED%" exec ollama ollama create "%LOCAL_AI_MODEL%" -f /Modelfile.planner
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

:pin_docker_api_version
set "ORIGINAL_DOCKER_API_VERSION=%DOCKER_API_VERSION%"
set "DOCKER_API_VERSION="
set "SERVER_DOCKER_API_VERSION="
for /f "delims=" %%V in ('docker version --format "{{.Server.APIVersion}}" 2^>NUL') do set "SERVER_DOCKER_API_VERSION=%%V"
if defined SERVER_DOCKER_API_VERSION (
  set "DOCKER_API_VERSION=%SERVER_DOCKER_API_VERSION%"
  echo Docker Engine API version: %SERVER_DOCKER_API_VERSION%
  exit /b 0
)
if defined ORIGINAL_DOCKER_API_VERSION set "DOCKER_API_VERSION=%ORIGINAL_DOCKER_API_VERSION%"
echo ERROR: Docker Engine is not reachable or API negotiation failed.
echo Try restarting Docker Desktop, then run: docker version
docker version
exit /b 1
