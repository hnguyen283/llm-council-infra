@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-backend-sbom.ps1" %*
exit /b %ERRORLEVEL%
