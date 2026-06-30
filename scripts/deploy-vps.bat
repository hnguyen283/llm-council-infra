@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
if "%~1"=="" (
  set "OPTION=prod-lite-vps"
) else (
  echo %~1 | findstr /B /C:"-" >NUL 2>&1
  if errorlevel 1 (
    set "OPTION=%~1"
    shift /1
  ) else (
    set "OPTION=prod-lite-vps"
  )
)

set "DEPLOY_ARGS="
:collect_args
if "%~1"=="" goto args_done
set DEPLOY_ARGS=%DEPLOY_ARGS% "%~1"
shift /1
goto collect_args
:args_done

set "OPTION_DIR=%ROOT%\options\%OPTION%"
set "ENV_FILE=%OPTION_DIR%\.env"
set "PROJECT_ROOT=%ROOT%\.."
set "REPO_ROOT=%ROOT%\..\llm-council"
set "INFRA_ROOT=%ROOT%"
set "HELPER=%ROOT%\projects\scripts\deploy-vps-runtime-env.ps1"

if not exist "%OPTION_DIR%\option.env" (
  echo ERROR: Unknown deployment option "%OPTION%".
  echo Available options:
  for /d %%D in ("%ROOT%\options\*") do echo   %%~nxD
  exit /b 1
)

findstr /B /I /C:"OPTION_KIND=vps" "%OPTION_DIR%\option.env" >NUL 2>&1
if errorlevel 1 (
  echo ERROR: "%OPTION%" is not a VPS deployment option.
  echo Use scripts\start.bat %OPTION% for local compose options.
  exit /b 1
)

if not exist "%ENV_FILE%" (
  echo ERROR: Missing untracked deployment environment file:
  echo   %ENV_FILE%
  echo Create it from env\secrets.example.env and populate the required values.
  exit /b 1
)

if not exist "%HELPER%" (
  echo ERROR: helper script not found:
  echo   %HELPER%
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -ProjectRoot "%PROJECT_ROOT%" -RepoRoot "%REPO_ROOT%" -InfraRoot "%INFRA_ROOT%" -EnvPath "%ENV_FILE%" %DEPLOY_ARGS%
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%
