@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bp15-graduation-checks.ps1" %*
exit /b %ERRORLEVEL%
