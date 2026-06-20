@echo off
REM Launcher for the ASSISTED SAMPLE-DATA flow. Invokes pwsh 7 via -Command (NOT
REM -File) so stdin/Read-Host work. Double-click this OR run from any shell.
REM
REM We cd to %TEMP% BEFORE launching pwsh so neither cmd.exe nor pwsh keeps a
REM handle on the package folder as their working directory - that lets you
REM delete the downloaded folder immediately after a run without "folder in use"
REM errors from Explorer / OneDrive / Defender.
set SCRIPT_DIR=%~dp0
cd /d %TEMP%
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& '%SCRIPT_DIR%deploy-sampledata.ps1'"
set DEPLOY_EXIT=%errorlevel%
echo.
if %DEPLOY_EXIT% NEQ 0 (
    echo Deployment FAILED ^(exit %DEPLOY_EXIT%^). Review the output above; full log is in the 'logs' folder.
) else (
    echo Deployment finished. Review the output above; full log is in the 'logs' folder.
)
echo Press any key to close this window.
pause >nul
exit /b %DEPLOY_EXIT%
