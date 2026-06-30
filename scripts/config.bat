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

docker compose %ENV_ARGS% %FILE_ARGS% %PROFILE_ARGS% config > "%OUT_DIR%\compose.resolved.yaml"
if errorlevel 1 (
  echo ERROR: failed to write rendered Compose config.
  exit /b 1
)

call :write_masked_environment "%OUT_DIR%\environment.resolved.txt"

echo Rendered Compose config: %OUT_DIR%\compose.resolved.yaml
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

:write_masked_environment
set "DEST=%~1"
break > "%DEST%"
for %%E in (defaults workspace modes\%MODE% option local.user.override) do rem keep parser simple
for /f "usebackq tokens=1,* delims==" %%A in ("%ROOT%\env\defaults.env") do call :write_env_line "%DEST%" "%%A" "%%B"
if exist "%ROOT%\env\workspace.env" for /f "usebackq tokens=1,* delims==" %%A in ("%ROOT%\env\workspace.env") do call :write_env_line "%DEST%" "%%A" "%%B"
if exist "%ROOT%\env\modes\%MODE%.env" for /f "usebackq tokens=1,* delims==" %%A in ("%ROOT%\env\modes\%MODE%.env") do call :write_env_line "%DEST%" "%%A" "%%B"
for /f "usebackq tokens=1,* delims==" %%A in ("%OPTION_DIR%\option.env") do call :write_env_line "%DEST%" "%%A" "%%B"
if exist "%OPTION_DIR%\.env" for /f "usebackq tokens=1,* delims==" %%A in ("%OPTION_DIR%\.env") do call :write_env_line "%DEST%" "%%A" "%%B"
if exist "%ROOT%\env\local.user.override.env" for /f "usebackq tokens=1,* delims==" %%A in ("%ROOT%\env\local.user.override.env") do call :write_env_line "%DEST%" "%%A" "%%B"
exit /b 0

:write_env_line
set "DEST=%~1"
set "KEY=%~2"
set "VALUE=%~3"
if "%KEY%"=="" exit /b 0
if "%KEY:~0,1%"=="#" exit /b 0
echo %KEY% | findstr /R /I "PASSWORD SECRET TOKEN PRIVATE PEM API_KEY HMAC_KEY SIGNING_KEY" >NUL
if errorlevel 1 (
  >> "%DEST%" echo %KEY%=%VALUE%
) else (
  if "%VALUE%"=="" (
    >> "%DEST%" echo %KEY%=
  ) else (
    >> "%DEST%" echo %KEY%=***
  )
)
exit /b 0
