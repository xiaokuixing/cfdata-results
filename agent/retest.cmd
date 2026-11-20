@echo off
chcp 65001 >nul
setlocal
set "HERE=%~dp0"
if not exist "%HERE%retest.txt" (
    echo missing retest.txt
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%agent.ps1" -Force -SourceFile "%HERE%retest.txt"
echo.
echo done - press any key to close
pause >nul