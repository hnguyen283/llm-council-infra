@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0.."
set "FAILED=0"

for %%F in ("%ROOT%\env\defaults.env" "%ROOT%\env\modes\http.env" "%ROOT%\env\modes\https.env" "%ROOT%\options\*\option.env") do (
  if exist "%%~F" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%%~F") do (
      set "KEY=%%A"
      set "VALUE=%%B"
      if not "!KEY!"=="" if not "!KEY:~0,1!"=="#" (
        echo !KEY! | findstr /R /I "_FILE$ _DIR$" >NUL
        if errorlevel 1 (
          echo !KEY! | findstr /R /I "PASSWORD SECRET TOKEN PRIVATE PEM API_KEY HMAC_KEY SIGNING_KEY" >NUL
          if not errorlevel 1 if not "!VALUE!"=="" call :fail "tracked secret-like value is non-empty in %%~F: !KEY!"
        )
      )
    )
  )
)

for /d %%D in ("%ROOT%\options\*") do call :validate_option "%%~fD" "%%~nxD"

if "%FAILED%"=="1" exit /b 1
echo Environment and option contract checks passed.
exit /b 0

:validate_option
set "OPTION_DIR=%~1"
set "OPTION=%~2"
if not exist "%OPTION_DIR%\option.env" exit /b 0

call :option_value OPTION_NAME
if /I not "!OPTION_VALUE!"=="%OPTION%" call :fail "%OPTION% OPTION_NAME must match its directory name"
if not exist "%OPTION_DIR%\compose.files" exit /b 0

call :option_value OPTION_KIND
if /I "!OPTION_VALUE!"=="vps-deploy" exit /b 0
if /I "!OPTION_VALUE!"=="vps-hybrid" exit /b 0

call :option_value PUBLIC_SCHEME
set "SCHEME=!OPTION_VALUE!"
if /I not "!SCHEME!"=="http" if /I not "!SCHEME!"=="https" call :fail "%OPTION% PUBLIC_SCHEME must be http or https"
call :option_value PUBLIC_HOST
set "HOST_NAME=!OPTION_VALUE!"
if "!HOST_NAME!"=="" call :fail "%OPTION% PUBLIC_HOST is required"
call :option_value PUBLIC_PORT
set "PORT=!OPTION_VALUE!"
echo !PORT!| findstr /R "^[0-9][0-9]*$" >NUL
if errorlevel 1 call :fail "%OPTION% PUBLIC_PORT must be numeric"
call :option_value PUBLIC_ORIGIN
set "EXPECTED_ORIGIN=!SCHEME!://!HOST_NAME!:!PORT!"
if /I "!SCHEME!"=="https" if "!PORT!"=="443" set "EXPECTED_ORIGIN=https://!HOST_NAME!"
if /I "!SCHEME!"=="http" if "!PORT!"=="80" set "EXPECTED_ORIGIN=http://!HOST_NAME!"
if /I not "!OPTION_VALUE!"=="!EXPECTED_ORIGIN!" call :fail "%OPTION% PUBLIC_ORIGIN must derive from scheme, host, and port"

echo %OPTION%| findstr /B /I "prod-" >NUL
if not errorlevel 1 (
  call :option_value UI_RUNTIME_MODE
  if /I not "!OPTION_VALUE!"=="nginx-static" call :fail "%OPTION% must use nginx-static UI runtime"
  call :option_value PRODUCTION_LIKE_UI
  if /I not "!OPTION_VALUE!"=="true" call :fail "%OPTION% must declare PRODUCTION_LIKE_UI=true"
  call :file_has_line "%OPTION_DIR%\compose.files" "compose/compose.ui-nginx.yaml"
  if not defined HAS_LINE call :fail "%OPTION% must include compose.ui-nginx.yaml"
)

echo %OPTION%| findstr /B /I "dev-full-" >NUL
if not errorlevel 1 (
  call :option_value UI_RUNTIME_MODE
  if /I not "!OPTION_VALUE!"=="angular-dev-server" call :fail "%OPTION% must use angular-dev-server"
  call :option_value PRODUCTION_LIKE_UI
  if /I not "!OPTION_VALUE!"=="false" call :fail "%OPTION% must declare PRODUCTION_LIKE_UI=false"
  call :file_has_line "%OPTION_DIR%\compose.files" "compose/compose.ui-dev.yaml"
  if not defined HAS_LINE call :fail "%OPTION% must include compose.ui-dev.yaml"
)

if /I "!SCHEME!"=="https" (
  call :option_value AUTH_COOKIE_SECURE
  if /I not "!OPTION_VALUE!"=="true" call :fail "%OPTION% must enable secure auth cookies"
  call :option_value TLS_TERMINATION
  if /I not "!OPTION_VALUE!"=="cloudflare" (
    call :option_value LOCAL_TLS_TRUST_REQUIRED
    if /I not "!OPTION_VALUE!"=="true" if /I not "!OPTION_VALUE!"=="false" call :fail "%OPTION% LOCAL_TLS_TRUST_REQUIRED must be true or false"
  )
)

if /I "!OPTION:~-7!"=="-tunnel" (
  call :file_has_line "%OPTION_DIR%\compose.files" "compose/compose.tunnel.yaml"
  if not defined HAS_LINE call :fail "%OPTION% must include compose.tunnel.yaml"
  call :file_has_line "%OPTION_DIR%\compose.files" "compose/compose.edge-http.yaml"
  if not defined HAS_LINE call :fail "%OPTION% must use the internal HTTP edge behind Cloudflare TLS"
  call :file_has_line "%OPTION_DIR%\profiles.txt" "tunnel"
  if not defined HAS_LINE call :fail "%OPTION% must enable the tunnel profile"
  call :option_value TLS_TERMINATION
  if /I not "!OPTION_VALUE!"=="cloudflare" call :fail "%OPTION% must declare TLS_TERMINATION=cloudflare"
  call :option_value EDGE_CONTAINER_PORT
  if not "!OPTION_VALUE!"=="8080" call :fail "%OPTION% tunnel origin must target portal-edge HTTP port 8080"
  call :option_value EDGE_FORWARDED_PROTO
  if /I not "!OPTION_VALUE!"=="https" call :fail "%OPTION% must forward the public HTTPS scheme"
  call :option_value EDGE_FORWARDED_PORT
  if not "!OPTION_VALUE!"=="443" call :fail "%OPTION% must forward public port 443"
  call :option_value LOCAL_SERVICE_MAPPING
  if /I not "!OPTION_VALUE!"=="http://localhost:8080" call :fail "%OPTION% must match the remotely managed Cloudflare origin"
)
exit /b 0

:option_value
set "OPTION_VALUE="
for /f "usebackq tokens=1,* delims==" %%A in ("%OPTION_DIR%\option.env") do if /I "%%A"=="%~1" set "OPTION_VALUE=%%B"
exit /b 0

:file_has_line
set "HAS_LINE="
if not exist "%~1" exit /b 0
for /f "usebackq tokens=* delims=" %%L in ("%~1") do if /I "%%L"=="%~2" set "HAS_LINE=1"
exit /b 0

:fail
echo ERROR: %~1
set "FAILED=1"
exit /b 0
