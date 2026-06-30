@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0.."
set "FAILED=0"

for %%F in ("%ROOT%\env\defaults.env" "%ROOT%\env\modes\http.env" "%ROOT%\env\modes\https.env" "%ROOT%\options\*\option.env") do (
  if exist "%%~F" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%%~F") do (
      set "KEY=%%A"
      set "VALUE=%%B"
      if not "!KEY!"=="" if not "!KEY:~0,1!"=="#" (
        echo !KEY! | findstr /R /I "PASSWORD SECRET TOKEN PRIVATE PEM API_KEY HMAC_KEY SIGNING_KEY" >NUL
        if not errorlevel 1 if not "!VALUE!"=="" (
          echo ERROR: tracked secret-like value is non-empty in %%~F: !KEY!
          set "FAILED=1"
        )
      )
    )
  )
)

if "%FAILED%"=="1" exit /b 1
echo Environment contract check passed.
exit /b 0
