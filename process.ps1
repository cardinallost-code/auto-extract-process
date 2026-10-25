#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath,

    [switch]$Run,
    [switch]$SkipRenamer,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-WithError([string]$Message, [int]$Code = 1) {
    Write-Host "[错误] $Message" -ForegroundColor Red
    exit $Code
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Stop-WithError "找不到配置文件：$ConfigPath"
}

try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    Stop-WithError "配置文件无法读取：$($_.Exception.Message)"
}

$resolvedInputs = [Collections.Generic.List[string]]::new()
foreach ($path in $InputPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Stop-WithError "处理输入必须是已解压的目录：$path"
    }
    $resolved = (Resolve-Path -LiteralPath $path).Path
    if (-not $resolvedInputs.Contains($resolved)) { $resolvedInputs.Add($resolved) }
}
if ($resolvedInputs.Count -eq 0) { Stop-WithError "没有有效输入目录" }
$renamer = $config.plugins.dlsite_renamer
$audio = $config.plugins.wav_to_mp3
$fileProcessor = Join-Path $PSScriptRoot 'file-process.ps1'

Write-Host ""
Write-Host "处理阶段计划" -ForegroundColor Cyan
Write-Host "输入目录：$($resolvedInputs.Count) 个"
$resolvedInputs | ForEach-Object { Write-Host "  $_" }
Write-Host "执行模式：$(if ($Run) { '执行' } else { '预演' })"
Write-Host ""

$step = 0
if ($renamer.enabled -and -not $SkipRenamer) {
    $step++
    Write-Host "$step. DLsite 作品识别及目录重命名（人工界面节点）"
    Write-Host "   程序：$($renamer.executable)"
}

if ($audio.enabled) {
    $step++
    Write-Host "$step. 优先采用原生 MP3，仅转换缺少原生 MP3 的 WAV"
    Write-Host "   处理器：$fileProcessor"
}

if (-not $Run) {
    Write-Host ""
    Write-Host "当前仅预演，没有启动程序或修改文件。添加 -Run 后执行。" -ForegroundColor Yellow
    exit 0
}

if ($renamer.enabled -and -not $SkipRenamer) {
    if (-not (Test-Path -LiteralPath $renamer.executable -PathType Leaf)) {
        Stop-WithError "找不到 DLsite 重命名插件：$($renamer.executable)"
    }
    if (-not (Test-Path -LiteralPath $renamer.working_directory -PathType Container)) {
        Stop-WithError "找不到 DLsite 重命名插件目录：$($renamer.working_directory)"
    }

    Write-Host ""
    Write-Host "正在启动 DLsite 重命名工具。请在工具中处理：" -ForegroundColor Cyan
    $resolvedInputs | ForEach-Object { Write-Host "  $_" }
    Write-Host "完成后关闭重命名工具，流水线将继续。"

    $process = Start-Process `
        -FilePath $renamer.executable `
        -WorkingDirectory $renamer.working_directory `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        Stop-WithError "DLsite 重命名工具退出代码：$($process.ExitCode)"
    }
}

if ($audio.enabled) {
    if (-not (Test-Path -LiteralPath $fileProcessor -PathType Leaf)) {
        Stop-WithError "找不到文件处理器：$fileProcessor"
    }

    Write-Host ""
    Write-Host "开始 WAV → MP3 处理……" -ForegroundColor Cyan
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $fileProcessor @resolvedInputs -Run
    $audioExitCode = $LASTEXITCODE

    if ($audioExitCode -ne 0) {
        Stop-WithError "WAV 转 MP3 插件未完全成功，退出代码：$audioExitCode" $audioExitCode
    }
}

Write-Host ""
Write-Host "处理阶段已完成。原始 WAV 当前保留。" -ForegroundColor Green
exit 0
