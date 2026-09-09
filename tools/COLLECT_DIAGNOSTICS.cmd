@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect_diagnostics.ps1" %*
set "diagnosticsExit=%ERRORLEVEL%"
if not "%diagnosticsExit%"=="0" echo Diagnostics collection failed. Please share the error shown above.
echo.
pause
exit /b %diagnosticsExit%
