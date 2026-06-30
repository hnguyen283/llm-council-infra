@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0.."
if "%~1"=="" (
  set "OPTION=prod-full-local-http"
) else (
  set "OPTION=%~1"
)
set "OPTION_DIR=%ROOT%\options\%OPTION%"
if not exist "%OPTION_DIR%\option.env" (
  echo ERROR: Unknown option "%OPTION%".
  exit /b 1
)
set "MODE=http"
findstr /B /I /C:"PUBLIC_SCHEME=https" "%OPTION_DIR%\option.env" >NUL 2>&1
if not errorlevel 1 set "MODE=https"

echo === Docker ===
docker compose version
if errorlevel 1 exit /b 1
docker info >NUL 2>&1
if errorlevel 1 (
  echo ERROR: Docker Engine is not reachable.
  exit /b 1
)

echo.
echo === Option manifest ===
call "%ROOT%\scripts\config.bat" "%OPTION%"
if errorlevel 1 exit /b 1

echo.
echo === Required secret presence ===
set "MISSING=0"
for %%V in (POSTGRES_PASSWORD ACCOUNT_DB_PASSWORD PROMPT_DB_PASSWORD VALKEY_PASSWORD AUTH_JWT_PRIVATE_KEY_PEM AUTH_JWT_PUBLIC_KEYS_PEM GATEWAY_INTERNAL_PRIVATE_KEY_PEM GATEWAY_INTERNAL_PUBLIC_KEYS_PEM ACCOUNT_INTERNAL_SERVICE_TOKEN TENANT_NAMESPACE_HMAC_KEY) do (
  call :find_value %%V
  if "!FOUND_VALUE!"=="" (
    echo MISSING: %%V
    set "MISSING=1"
  ) else (
    echo PRESENT: %%V
  )
)
if "%MISSING%"=="1" (
  echo.
  echo ERROR: Required secrets are missing. Put local values in an untracked env file.
  exit /b 1
)

echo.
echo Doctor passed for %OPTION%.
exit /b 0

:find_value
set "TARGET=%~1"
set "FOUND_VALUE="
for %%F in ("%ROOT%\env\defaults.env" "%ROOT%\env\workspace.env" "%ROOT%\env\modes\%MODE%.env" "%OPTION_DIR%\option.env" "%ROOT%\env\local.user.override.env") do (
  if exist "%%~F" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%%~F") do (
      if "%%A"=="%TARGET%" set "FOUND_VALUE=%%B"
    )
  )
)
exit /b 0
