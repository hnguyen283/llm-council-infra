@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0.."
if "%~1"=="" (set "OPTION=prod-full-local-http") else (set "OPTION=%~1")
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
set "REQUIRED_SECRETS=POSTGRES_PASSWORD ACCOUNT_DB_PASSWORD PROMPT_DB_PASSWORD VALKEY_PASSWORD AUTH_JWT_PRIVATE_KEY_PEM AUTH_JWT_PUBLIC_KEYS_PEM AUTH_GOOGLE_SIGNUP_SECRET ACCOUNT_INTERNAL_SERVICE_TOKEN TENANT_NAMESPACE_HMAC_KEY"
call :find_value GRAPHRAG_ENABLED
if /I "!FOUND_VALUE!"=="true" set "REQUIRED_SECRETS=!REQUIRED_SECRETS! GRAPHRAG_DB_PASSWORD"
for %%V in (!REQUIRED_SECRETS!) do (
  call :find_value %%V
  if "!FOUND_VALUE!"=="" (
    echo MISSING: %%V
    set "MISSING=1"
  ) else (
    echo PRESENT: %%V ^(environment compatibility^)
  )
)

call :check_gateway_key GATEWAY_INTERNAL_PRIVATE_KEY_PEM private-key.pem
call :check_gateway_key GATEWAY_INTERNAL_PUBLIC_KEYS_PEM public-keys.pem

call :find_value TLS_TERMINATION
set "TLS_TERMINATION=!FOUND_VALUE!"
call :find_value LOCAL_TLS_TRUST_REQUIRED
set "LOCAL_TLS_TRUST_REQUIRED=!FOUND_VALUE!"
if not defined LOCAL_TLS_TRUST_REQUIRED set "LOCAL_TLS_TRUST_REQUIRED=true"
if /I "%MODE%"=="https" if /I not "!TLS_TERMINATION!"=="cloudflare" (
  call :find_value HTTPS_CERT_DIR
  set "CERT_DIR=!FOUND_VALUE!"
  if exist "!CERT_DIR!\cert.pem" (
    set "RESOLVED_CERT_DIR=!CERT_DIR!"
  ) else (
    set "RESOLVED_CERT_DIR=%ROOT%\compose\!CERT_DIR!"
  )
  if not exist "!RESOLVED_CERT_DIR!\cert.pem" (
    echo MISSING: HTTPS cert.pem
    set "MISSING=1"
  )
  if not exist "!RESOLVED_CERT_DIR!\key.pem" (
    echo MISSING: HTTPS key.pem
    set "MISSING=1"
  )
  if exist "!RESOLVED_CERT_DIR!\cert.pem" if exist "!RESOLVED_CERT_DIR!\key.pem" (
    call :find_value PUBLIC_HOST
    if /I "!LOCAL_TLS_TRUST_REQUIRED!"=="true" (
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\check-tls-certificate.ps1" -CertificatePath "!RESOLVED_CERT_DIR!\cert.pem" -ExpectedHost "!FOUND_VALUE!"
      if errorlevel 1 (
        echo INVALID: HTTPS certificate identity or local trust
        set "MISSING=1"
      )
    ) else (
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\check-tls-certificate.ps1" -CertificatePath "!RESOLVED_CERT_DIR!\cert.pem" -ExpectedHost "!FOUND_VALUE!" >NUL 2>&1
      if errorlevel 1 (
        echo OPTIONAL: HTTPS certificate identity/local trust did not pass; continuing because LOCAL_TLS_TRUST_REQUIRED=false
      ) else (
        echo VALID: optional HTTPS certificate identity/local trust check passed
      )
    )
  )
)
if /I "%MODE%"=="https" if /I "!TLS_TERMINATION!"=="cloudflare" echo PRESENT: public TLS terminates at Cloudflare; local origin uses the private Compose network

call :find_value TUNNEL_ENABLED
if /I "!FOUND_VALUE!"=="true" (
  call :find_value CLOUDFLARED_TUNNEL_TOKEN
  if "!FOUND_VALUE!"=="" (
    echo MISSING: CLOUDFLARED_TUNNEL_TOKEN
    set "MISSING=1"
  ) else (
    echo PRESENT: CLOUDFLARED_TUNNEL_TOKEN
  )
  call :find_value LOCAL_SERVICE_MAPPING
  if /I not "!FOUND_VALUE!"=="http://localhost:8080" (
    echo INVALID: LOCAL_SERVICE_MAPPING must match the remotely managed Cloudflare origin
    set "MISSING=1"
  ) else (
    echo PRESENT: Cloudflare origin contract http://localhost:8080
  )
)

if "%MISSING%"=="1" (
  echo.
  echo ERROR: Required option prerequisites are missing.
  exit /b 1
)

echo.
echo Doctor passed for %OPTION%.
exit /b 0

:find_value
set "TARGET=%~1"
set "FOUND_VALUE="
if defined %TARGET% call set "FOUND_VALUE=%%%TARGET%%%"
if defined FOUND_VALUE exit /b 0
for %%F in ("%ROOT%\env\defaults.env" "%ROOT%\env\workspace.env" "%ROOT%\env\modes\%MODE%.env" "%OPTION_DIR%\option.env" "%OPTION_DIR%\.env" "%ROOT%\env\local.user.override.env") do (
  if exist "%%~F" for /f "usebackq tokens=1,* delims==" %%A in ("%%~F") do if "%%A"=="%TARGET%" set "FOUND_VALUE=%%B"
)
exit /b 0

:check_gateway_key
call :find_value %~1
if defined FOUND_VALUE (
  echo PRESENT: %~1 ^(environment compatibility^)
  exit /b 0
)
if exist "%ROOT%\secrets\local\api-gateway\%~2" (
  for %%Z in ("%ROOT%\secrets\local\api-gateway\%~2") do if %%~zZ GTR 0 (
    echo PRESENT: %~1 ^(file-backed^)
    exit /b 0
  )
)
echo MISSING: %~1 ^(environment value or file-backed secret^)
set "MISSING=1"
exit /b 0
