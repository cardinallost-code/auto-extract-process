@echo off
setlocal
chcp 65001 >nul

set "PWSH=C:\Program Files\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
    echo [错误] 未找到 PowerShell 7。
    pause
    exit /b 1
)

if "%~1"=="" (
    echo 请把压缩包或包含压缩包的目录拖到此文件。
    echo 默认进行安全预演，不会解压或删除文件。
    pause
    exit /b 1
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0extract.ps1" %*
set "ERR=%ERRORLEVEL%"
echo.
pause
exit /b %ERR%
