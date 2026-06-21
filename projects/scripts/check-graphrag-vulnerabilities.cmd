@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-graphrag-vulnerabilities.ps1" %*
exit /b %ERRORLEVEL%
