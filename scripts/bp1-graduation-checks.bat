@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bp1-graduation-checks.ps1" %*
exit /b %ERRORLEVEL%
