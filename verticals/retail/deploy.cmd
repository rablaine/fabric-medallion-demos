@echo off
REM Launcher: invokes pwsh 7 via -Command (NOT -File) so stdin/Read-Host work.
REM Double-click this OR run `deploy.cmd` from any shell (cmd, powershell 5.1, pwsh).
REM
REM IMPORTANT: We cd to %TEMP% BEFORE launching pwsh so neither cmd.exe nor
REM pwsh keeps a handle on the package folder as their working directory. That
REM lets the user delete the downloaded folder immediately after a run (or even
REM mid-run if they need to abort), without "folder in use" errors from
REM Windows Explorer / OneDrive / Defender holding the dir open.
set SCRIPT_DIR=%~dp0
cd /d %TEMP%
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& '%SCRIPT_DIR%deploy.ps1'"
set DEPLOY_EXIT=%errorlevel%
if %DEPLOY_EXIT% NEQ 0 (
    echo.
    echo Deployment failed. Press any key to close.
    pause >nul
)
exit /b %DEPLOY_EXIT%
