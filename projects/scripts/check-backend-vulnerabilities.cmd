@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-backend-vulnerabilities.ps1" %*
exit /b %ERRORLEVEL%
