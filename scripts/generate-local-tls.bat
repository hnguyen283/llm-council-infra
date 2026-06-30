@echo off
setlocal EnableExtensions
set "ROOT=%~dp0.."
set "SSL_DIR=%ROOT%\ssl"
if not exist "%SSL_DIR%" mkdir "%SSL_DIR%" >NUL 2>&1

where mkcert >NUL 2>&1
if not errorlevel 1 (
  echo Generating locally trusted certificate with mkcert.
  pushd "%SSL_DIR%"
  mkcert -cert-file cert.pem -key-file key.pem localhost 127.0.0.1 ::1
  set "EXIT_CODE=%ERRORLEVEL%"
  popd
  exit /b %EXIT_CODE%
)

where openssl >NUL 2>&1
if errorlevel 1 (
  echo ERROR: Install mkcert or OpenSSL to generate local TLS material.
  exit /b 1
)

echo mkcert not found. Generating self-signed certificate with OpenSSL.
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes ^
  -keyout "%SSL_DIR%\key.pem" ^
  -out "%SSL_DIR%\cert.pem" ^
  -subj "/CN=localhost" ^
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
exit /b %ERRORLEVEL%
