@echo off
REM ============================================================================
REM laptop-local-ai.cmd -- Run the laptop side of the prod-lite deployment.
REM
REM Starts:
REM   - Local knowledge database (Postgres) on port 5433.
REM   - Ollama in Docker, exposed on localhost:11434.
REM   - local-ai-service from the packaged Spring Boot JAR.
REM
REM This script does not start the VPS/public stack. It expects the remote Kafka
REM broker to be reached through an SSH local-forward opened from hostInfo.txt:
REM   laptop 127.0.0.1:9092 -> VPS 127.0.0.1:9092 -> kafka container :9092
REM ============================================================================

setlocal EnableExtensions
cd /d "%~dp0"

if /i "%~1"=="--help" goto :help
if /i "%~1"=="-h" goto :help

set "ROOT=%~dp0"
set "ENV_FILE=%ROOT%prod-lite.env"
set "HOST_INFO=%ROOT%..\hostInfo.txt"
set "AI_FILES=-f projects\ai-runtime\docker-compose.yml -f projects\ai-runtime\overlays\dev-ports.yml"
set "LOCAL_DB_FILES=-f local\docker-compose.local-db.yml"

if not exist "%ENV_FILE%" (
    echo ERROR: %ENV_FILE% does not exist.
    echo Create prod-lite.env and set the prod-lite local/VPS runtime values.
    exit /b 1
)

call :load_env

if not defined LOCAL_AI_MODEL set "LOCAL_AI_MODEL=planner"
if not defined LOCAL_AI_WORKER_ID set "LOCAL_AI_WORKER_ID=local-ai-laptop"
if not defined LOCAL_AI_HEARTBEAT_INTERVAL_MS set "LOCAL_AI_HEARTBEAT_INTERVAL_MS=15000"
if not defined LOCAL_AI_HEARTBEAT_TTL_MS set "LOCAL_AI_HEARTBEAT_TTL_MS=60000"
if not defined CONFIG_SERVER_URI set "CONFIG_SERVER_URI=http://localhost:8888"
if not defined LOCAL_AI_SSH_TUNNEL_ENABLED set "LOCAL_AI_SSH_TUNNEL_ENABLED=true"
if not defined LOCAL_AI_KAFKA_TUNNEL_PORT set "LOCAL_AI_KAFKA_TUNNEL_PORT=9092"

if /i not "%LOCAL_AI_SSH_TUNNEL_ENABLED%"=="false" (
    if not exist "%HOST_INFO%" (
        echo ERROR: %HOST_INFO% does not exist.
        echo The laptop Kafka bridge needs hostInfo.txt so it can open an SSH tunnel to the VPS.
        exit /b 1
    )
    call :load_host_info
    if not defined VPS_SSH_HOST ( echo ERROR: hostInfo.txt is missing IP. & exit /b 1 )
    if not defined VPS_SSH_USER ( echo ERROR: hostInfo.txt is missing Username. & exit /b 1 )
    if not defined VPS_SSH_PORT set "VPS_SSH_PORT=22"
    if not defined VPS_SSH_PASSWORD (
        echo ERROR: hostInfo.txt is missing Password.
        echo Configure SSH key auth manually or set LOCAL_AI_SSH_TUNNEL_ENABLED=false and provide REMOTE_KAFKA_BOOTSTRAP_SERVERS.
        exit /b 1
    )
    set "REMOTE_KAFKA_BOOTSTRAP_SERVERS=localhost:%LOCAL_AI_KAFKA_TUNNEL_PORT%"
) else if not defined REMOTE_KAFKA_BOOTSTRAP_SERVERS (
    echo WARNING: REMOTE_KAFKA_BOOTSTRAP_SERVERS is not set in prod-lite.env.
    echo          Falling back to localhost:9092 for local development only.
    set "REMOTE_KAFKA_BOOTSTRAP_SERVERS=localhost:9092"
)

echo.
echo === [laptop-local-ai] Checking local tools ===
docker compose version
if errorlevel 1 ( echo Docker Compose is not available. Aborting. & exit /b 1 )
docker info >NUL 2>&1
if errorlevel 1 ( echo Docker Engine is not reachable. Start Docker Desktop. & exit /b 1 )
java -version >NUL 2>&1
if errorlevel 1 ( echo Java is not available on PATH. Aborting. & exit /b 1 )

echo.
echo === [laptop-local-ai] Ensuring Docker networks exist ===
docker network inspect llm-council-ai-runtime >NUL 2>&1
if errorlevel 1 (
    docker network create -d bridge llm-council-ai-runtime >NUL
    if errorlevel 1 ( echo Failed to create llm-council-ai-runtime. & exit /b 1 )
    echo Created network llm-council-ai-runtime.
)
docker network inspect llm-council-data >NUL 2>&1
if errorlevel 1 (
    docker network create -d bridge llm-council-data >NUL
    if errorlevel 1 ( echo Failed to create llm-council-data. & exit /b 1 )
    echo Created network llm-council-data.
)

echo.
echo === [laptop-local-ai] Starting local Postgres database (knowledge_db on 5433) ===
docker compose --env-file "%ENV_FILE%" %LOCAL_DB_FILES% up -d --wait postgres-knowledge
if errorlevel 1 (
    echo Local database failed to start. Inspect with:
    echo   docker compose --env-file "%ENV_FILE%" %LOCAL_DB_FILES% logs postgres-knowledge
    exit /b 1
)

echo.
echo === [laptop-local-ai] Starting Ollama container ===
docker compose --env-file "%ENV_FILE%" %AI_FILES% up -d --wait ollama
if errorlevel 1 (
    echo Ollama failed to start. Inspect with:
    echo   docker compose --env-file "%ENV_FILE%" %AI_FILES% logs ollama
    exit /b 1
)

echo.
echo === [laptop-local-ai] Ensuring planner model exists ===
docker compose --env-file "%ENV_FILE%" %AI_FILES% exec ollama ollama pull deepseek-r1:7b
if errorlevel 1 ( echo Model pull failed. Aborting. & exit /b 1 )
docker compose --env-file "%ENV_FILE%" %AI_FILES% exec ollama ollama create planner -f /Modelfile.planner
if errorlevel 1 ( echo Planner model creation failed. Aborting. & exit /b 1 )

echo.
echo === [laptop-local-ai] Building local-ai-service JAR ===
pushd "%ROOT%..\llm-council"
call mvn -pl common,local-ai-service -am -DskipTests package
popd
if errorlevel 1 ( echo Maven package failed. Aborting. & exit /b 1 )

set "LOCAL_AI_JAR="
for /f "delims=" %%J in ('dir /b /a:-d "%ROOT%..\llm-council\local-ai-service\target\local-ai-service-*.jar" 2^>NUL') do (
    set "LOCAL_AI_JAR=%ROOT%..\llm-council\local-ai-service\target\%%J"
)
if not defined LOCAL_AI_JAR (
    echo ERROR: local-ai-service JAR was not found under local-ai-service\target.
    exit /b 1
)

echo.
echo === [laptop-local-ai] Starting local-ai-service ===
if /i not "%LOCAL_AI_SSH_TUNNEL_ENABLED%"=="false" (
    call :start_kafka_tunnel
    if errorlevel 1 ( call :stop_kafka_tunnel & exit /b 1 )
)
echo Kafka bootstrap: %REMOTE_KAFKA_BOOTSTRAP_SERVERS%
echo Close this window to stop local-ai-service. Ollama and local DB remain running in Docker.

set "SPRING_APPLICATION_NAME=local-ai-service"
set "SPRING_PROFILES_ACTIVE=remote-worker"
set "SPRING_CONFIG_IMPORT=optional:configserver:%CONFIG_SERVER_URI%"
set "SPRING_CLOUD_CONFIG_FAIL_FAST=false"
set "SPRING_KAFKA_BOOTSTRAP_SERVERS=%REMOTE_KAFKA_BOOTSTRAP_SERVERS%"
set "SPRING_KAFKA_CONSUMER_GROUP_ID=local-ai-workers"
set "SERVER_PORT=8086"
set "EUREKA_CLIENT_REGISTER_WITH_EUREKA=false"
set "EUREKA_CLIENT_FETCH_REGISTRY=false"
set "MANAGEMENT_TRACING_SAMPLING_PROBABILITY=0.0"
set "OLLAMA_BASE_URL=http://localhost:11434"
set "LOCAL_AI_BASE_URL=http://localhost:11434"
set "LOCAL_AI_HEARTBEAT_ENABLED=true"

java -jar "%LOCAL_AI_JAR%"
set "EXIT_CODE=%ERRORLEVEL%"
call :stop_kafka_tunnel
endlocal & exit /b %EXIT_CODE%

:load_env
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ENV_FILE%") do (
    if not "%%A"=="" set "%%A=%%B"
)
exit /b 0

:load_host_info
for /f "usebackq eol=# tokens=1,* delims==:" %%A in ("%HOST_INFO%") do (
    call :assign_host_info "%%A" "%%B"
)
exit /b 0

:assign_host_info
set "HOST_KEY=%~1"
set "HOST_VALUE=%~2"
if /i "%HOST_KEY%"=="IP" set "VPS_SSH_HOST=%HOST_VALUE%"
if /i "%HOST_KEY%"=="Username" set "VPS_SSH_USER=%HOST_VALUE%"
if /i "%HOST_KEY%"=="PortSSH" set "VPS_SSH_PORT=%HOST_VALUE%"
if /i "%HOST_KEY%"=="Password" set "VPS_SSH_PASSWORD=%HOST_VALUE%"
exit /b 0

:start_kafka_tunnel
echo.
echo === [laptop-local-ai] Starting SSH tunnel for Kafka ===
where plink.exe >NUL 2>&1
if errorlevel 1 (
    echo ERROR: plink.exe was not found on PATH. Install PuTTY or set LOCAL_AI_SSH_TUNNEL_ENABLED=false.
    exit /b 1
)
for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $plink=(Get-Command plink.exe -ErrorAction Stop).Source; $args=@('-ssh','-N','-batch','-P',$env:VPS_SSH_PORT,'-l',$env:VPS_SSH_USER,'-pw',$env:VPS_SSH_PASSWORD,'-L',('127.0.0.1:'+$env:LOCAL_AI_KAFKA_TUNNEL_PORT+':127.0.0.1:9092'),$env:VPS_SSH_HOST); $p=Start-Process -FilePath $plink -ArgumentList $args -WindowStyle Hidden -PassThru; $p.Id"`) do set "KAFKA_TUNNEL_PID=%%P"
if not defined KAFKA_TUNNEL_PID (
    echo ERROR: failed to start the Kafka SSH tunnel.
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$deadline=(Get-Date).AddSeconds(20); do { Start-Sleep -Milliseconds 500; $ok=(Test-NetConnection -ComputerName 127.0.0.1 -Port ([int]$env:LOCAL_AI_KAFKA_TUNNEL_PORT) -InformationLevel Quiet) } until ($ok -or (Get-Date) -gt $deadline); if (-not $ok) { exit 1 }"
if errorlevel 1 (
    echo ERROR: Kafka SSH tunnel did not become reachable on 127.0.0.1:%LOCAL_AI_KAFKA_TUNNEL_PORT%.
    exit /b 1
)
echo Kafka SSH tunnel is ready on 127.0.0.1:%LOCAL_AI_KAFKA_TUNNEL_PORT%.
exit /b 0

:stop_kafka_tunnel
if defined KAFKA_TUNNEL_PID (
    echo.
    echo === [laptop-local-ai] Stopping SSH tunnel for Kafka ===
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Stop-Process -Id ([int]$env:KAFKA_TUNNEL_PID) -ErrorAction SilentlyContinue"
)
exit /b 0

:help
echo Usage: laptop-local-ai.cmd
echo.
echo Starts local knowledge database, Ollama, and local-ai-service using prod-lite.env.
echo Opens SSH tunnel from 127.0.0.1:9092 to the VPS Kafka using ..\hostInfo.txt.
exit /b 0
