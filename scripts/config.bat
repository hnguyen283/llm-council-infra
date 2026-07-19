@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0.."
if "%~1"=="" (
  set "OPTION=prod-full-local-http"
) else (
  set "OPTION=%~1"
)
set "OPTION_DIR=%ROOT%\options\%OPTION%"
if not exist "%OPTION_DIR%\option.env" (
  echo ERROR: Unknown option "%OPTION%".
  echo Available options:
  for /d %%D in ("%ROOT%\options\*") do echo   %%~nxD
  exit /b 1
)

if not exist "%OPTION_DIR%\compose.files" (
  echo Option: %OPTION%
  echo This option does not render a local Compose stack.
  echo Use the option-specific script documented in %OPTION_DIR%\README.md.
  exit /b 0
)

call "%ROOT%\scripts\check-env.bat"
if errorlevel 1 exit /b 1

set "MODE=http"
findstr /B /I /C:"PUBLIC_SCHEME=https" "%OPTION_DIR%\option.env" >NUL 2>&1
if not errorlevel 1 set "MODE=https"

set "OUT_DIR=%ROOT%\.generated\%OPTION%"
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%" >NUL 2>&1

set "ENV_ARGS="
set "ENV_LIST=%OUT_DIR%\environment.layers.txt"
break > "%ENV_LIST%"
call :add_env "env\defaults.env"
call :add_env "env\workspace.env"
call :add_env "env\modes\%MODE%.env"
call :add_env "options\%OPTION%\option.env"
call :add_env "options\%OPTION%\.env"
call :add_env "env\local.user.override.env"

set "FILE_ARGS="
set "FILE_LIST=%OUT_DIR%\compose.files.txt"
break > "%FILE_LIST%"
for /f "usebackq tokens=* delims=" %%L in ("%OPTION_DIR%\compose.files") do (
  set "LINE=%%L"
  if not "!LINE!"=="" if not "!LINE:~0,1!"=="#" (
    set "COMPOSE_FILE_PATH=%ROOT%\!LINE:/=\!"
    if not exist "!COMPOSE_FILE_PATH!" (
      echo ERROR: Compose file not found: !LINE!
      exit /b 1
    )
    set "FILE_ARGS=!FILE_ARGS! -f "!COMPOSE_FILE_PATH!""
    >> "%FILE_LIST%" echo !LINE!
  )
)

set "PROFILE_ARGS="
set "PROFILE_LIST=%OUT_DIR%\profiles.txt"
break > "%PROFILE_LIST%"
for /f "usebackq tokens=* delims=" %%P in ("%OPTION_DIR%\profiles.txt") do (
  set "PROFILE=%%P"
  if not "!PROFILE!"=="" if not "!PROFILE:~0,1!"=="#" (
    set "PROFILE_ARGS=!PROFILE_ARGS! --profile !PROFILE!"
    >> "%PROFILE_LIST%" echo !PROFILE!
  )
)

echo Option: %OPTION%
echo Environment layers:
type "%ENV_LIST%"
echo Compose files:
type "%FILE_LIST%"
echo Profiles:
type "%PROFILE_LIST%"

docker compose %ENV_ARGS% %FILE_ARGS% %PROFILE_ARGS% config --quiet
if errorlevel 1 (
  echo ERROR: docker compose config validation failed.
  exit /b 1
)

if exist "%OUT_DIR%\compose.resolved.yaml" del /Q "%OUT_DIR%\compose.resolved.yaml"
rem Persist only metadata that cannot contain interpolated secret values.
rem Runtime commands reassemble the validated Compose files from the lists above.
docker compose %ENV_ARGS% %FILE_ARGS% %PROFILE_ARGS% config --services > "%OUT_DIR%\compose.services.txt"
if errorlevel 1 (
  echo ERROR: failed to write the rendered service summary.
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\write-masked-environment.ps1" -OutputPath "%OUT_DIR%\environment.resolved.txt" -Root "%ROOT%" -EnvironmentListPath "%ENV_LIST%"
if errorlevel 1 (
  echo ERROR: failed to write the masked resolved environment summary.
  exit /b 1
)

echo Rendered service summary: %OUT_DIR%\compose.services.txt
echo Rendered environment summary: %OUT_DIR%\environment.resolved.txt
exit /b 0

:add_env
set "REL=%~1"
set "ABS=%ROOT%\%REL%"
if exist "%ABS%" (
  set "ENV_ARGS=%ENV_ARGS% --env-file "%ABS%""
  >> "%ENV_LIST%" echo %REL%
)
exit /b 0
