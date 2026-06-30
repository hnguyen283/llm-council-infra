@echo off
setlocal EnableExtensions
set "ROOT=%~dp0.."
if "%~1"=="" ( set "OPTION=prod-full-local-http" ) else ( set "OPTION=%~1" )
call "%ROOT%\scripts\config.bat" "%OPTION%"
if errorlevel 1 exit /b 1
docker compose -f "%ROOT%\.generated\%OPTION%\compose.resolved.yaml" logs -f --tail=200
