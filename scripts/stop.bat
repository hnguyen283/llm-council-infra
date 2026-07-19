@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0.."
if "%~1"=="" (set "OPTION=prod-full-local-http") else (set "OPTION=%~1")
call "%ROOT%\scripts\config.bat" "%OPTION%"
if errorlevel 1 exit /b 1
call :load_runtime_args
docker compose !ENV_ARGS! !FILE_ARGS! !PROFILE_ARGS! down --remove-orphans
exit /b %ERRORLEVEL%
:load_runtime_args
set "ENV_ARGS="
for /f "usebackq tokens=* delims=" %%L in ("%ROOT%\.generated\%OPTION%\environment.layers.txt") do if not "%%L"=="" set "ENV_ARGS=!ENV_ARGS! --env-file "%ROOT%\%%L""
set "FILE_ARGS="
for /f "usebackq tokens=* delims=" %%L in ("%ROOT%\.generated\%OPTION%\compose.files.txt") do if not "%%L"=="" set "FILE_ARGS=!FILE_ARGS! -f "%ROOT%\%%L""
set "PROFILE_ARGS="
for /f "usebackq tokens=* delims=" %%P in ("%ROOT%\.generated\%OPTION%\profiles.txt") do if not "%%P"=="" set "PROFILE_ARGS=!PROFILE_ARGS! --profile %%P"
exit /b 0
