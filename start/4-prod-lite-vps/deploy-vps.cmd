@echo off
REM ============================================================================
REM deploy-vps.cmd -- Option 4 VPS deployment entrypoint.
REM
REM Reads:
REM   - hostInfo.txt from the project root.
REM   - .env from this option directory.
REM
REM Delegates to a PowerShell helper so secrets can be streamed to the remote
REM shell over SSH without copying any .env file to the VPS.
REM ============================================================================

setlocal EnableExtensions
cd /d "%~dp0"
set "ROOT=%~dp0..\..\"
set "ENV_FILE=%~dp0.env"

set "PROJECT_ROOT=%ROOT%..\"
set "PROJECT_ROOT_ARG=%PROJECT_ROOT:~0,-1%"
set "REPO_ROOT=%ROOT%..\llm-council"
set "INFRA_ROOT=%ROOT:~0,-1%"
set "HELPER=%ROOT%projects\scripts\deploy-vps-runtime-env.ps1"

if not exist "%HELPER%" (
    echo ERROR: helper script not found:
    echo   %HELPER%
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -ProjectRoot "%PROJECT_ROOT_ARG%" -RepoRoot "%REPO_ROOT%" -InfraRoot "%INFRA_ROOT%" -EnvPath "%ENV_FILE%" %*
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%
