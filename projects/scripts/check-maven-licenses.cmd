@echo off
setlocal
cd /d "%~dp0\..\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-maven-licenses.ps1"
exit /b %ERRORLEVEL%
