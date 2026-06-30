@echo off
setlocal EnableExtensions

echo === Docker CLI ===
where docker
docker --version

echo.
echo === Docker context ===
docker context show
docker context ls

echo.
echo === Environment overrides ===
if defined DOCKER_HOST (
  echo DOCKER_HOST=%DOCKER_HOST%
) else (
  echo DOCKER_HOST is not set
)
if defined DOCKER_API_VERSION (
  echo DOCKER_API_VERSION=%DOCKER_API_VERSION%
) else (
  echo DOCKER_API_VERSION is not set
)

echo.
echo === API probes: current context ===
call :probe_current

echo.
echo === API probes: npipe docker_engine ===
call :probe_host "npipe:////./pipe/docker_engine"

echo.
echo === API probes: npipe dockerDesktopLinuxEngine ===
call :probe_host "npipe:////./pipe/dockerDesktopLinuxEngine"

echo.
echo If every probe fails, restart Docker Desktop's Linux engine:
echo   1. Quit Docker Desktop from the tray icon.
echo   2. Run: wsl --shutdown
echo   3. Start Docker Desktop again and wait until it says running.
echo   4. Run: scripts\docker-diagnose.bat
echo.
echo If only docker_engine works, run:
echo   set DOCKER_HOST=npipe:////./pipe/docker_engine
echo   scripts\start.bat prod-full-local-http
exit /b 0

:probe_current
set "SAVED_DOCKER_HOST=%DOCKER_HOST%"
set "DOCKER_HOST="
call :probe_versions
if defined SAVED_DOCKER_HOST set "DOCKER_HOST=%SAVED_DOCKER_HOST%"
exit /b 0

:probe_host
set "SAVED_DOCKER_HOST=%DOCKER_HOST%"
set "DOCKER_HOST=%~1"
call :probe_versions
if defined SAVED_DOCKER_HOST (
  set "DOCKER_HOST=%SAVED_DOCKER_HOST%"
) else (
  set "DOCKER_HOST="
)
exit /b 0

:probe_versions
for %%A in (1.54 1.53 1.52 1.51 1.50 1.49 1.48 1.47 1.46 1.45 1.44 1.43 1.42 1.41) do (
  set "DOCKER_API_VERSION=%%A"
  docker version --format "api=%%A server={{.Server.Version}} serverApi={{.Server.APIVersion}}" 2>NUL
  if not errorlevel 1 (
    echo PASS api=%%A
    set "DOCKER_API_VERSION="
    exit /b 0
  )
  echo FAIL api=%%A
)
set "DOCKER_API_VERSION="
exit /b 1
