@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bp15-load-proof.ps1" %*
exit /b %ERRORLEVEL%
