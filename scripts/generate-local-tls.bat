@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0.."
if "%~1"=="" (
  set "SSL_DIR=%ROOT%\ssl"
) else (
  set "REQUESTED_DIR=%~1"
  if "!REQUESTED_DIR:~1,1!"==":" (
    set "SSL_DIR=%~f1"
  ) else if "!REQUESTED_DIR:~0,2!"=="\\" (
    set "SSL_DIR=%~f1"
  ) else (
    set "SSL_DIR=%ROOT%\!REQUESTED_DIR!"
  )
)

where mkcert >NUL 2>&1
if errorlevel 1 (
  echo ERROR: mkcert is required for browser-trusted local HTTPS.
  echo Install mkcert and its local root CA, then retry.
  exit /b 1
)

if not exist "%SSL_DIR%" mkdir "%SSL_DIR%" >NUL 2>&1
if exist "%SSL_DIR%\cert.pem" (
  echo ERROR: Refusing to overwrite existing certificate: %SSL_DIR%\cert.pem
  echo Choose an empty output directory, for example: scripts\generate-local-tls.bat ssl-local
  exit /b 1
)
if exist "%SSL_DIR%\key.pem" (
  echo ERROR: Refusing to overwrite existing private key: %SSL_DIR%\key.pem
  echo Choose an empty output directory, for example: scripts\generate-local-tls.bat ssl-local
  exit /b 1
)

echo Generating locally trusted certificate with mkcert in %SSL_DIR%.
pushd "%SSL_DIR%"
mkcert -cert-file cert.pem -key-file key.pem localhost 127.0.0.1 ::1
set "EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %EXIT_CODE%
