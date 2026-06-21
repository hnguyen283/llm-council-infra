@echo off
setlocal
cd /d "%~dp0\..\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-image-vulnerabilities.ps1" %*
exit /b %ERRORLEVEL%
