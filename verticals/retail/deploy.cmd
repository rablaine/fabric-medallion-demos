@echo off
REM Launcher: invokes pwsh 7 via -Command (NOT -File) so stdin/Read-Host work.
REM Double-click this OR run `deploy.cmd` from any shell (cmd, powershell 5.1, pwsh).
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0deploy.ps1'"
if errorlevel 1 (
    echo.
    echo Deployment failed. Press any key to close.
    pause >nul
)
