@echo off
setlocal
chcp 65001 >nul

set "PWSH="
for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%I"

if not defined PWSH (
    echo [错误] 未找到 PowerShell 7（pwsh.exe）。
    pause
    exit /b 1
)

if "%~1"=="" (
    echo 用法：把已解压的作品父目录拖到此 BAT。
    echo 默认只显示处理计划，不修改文件。
    echo.
    pause
    exit /b 1
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0process.ps1" %*
set "ERR=%ERRORLEVEL%"

echo.
pause
exit /b %ERR%
