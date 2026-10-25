#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:PYTHONIOENCODING = 'utf-8'
$logDirectory = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$log = Join-Path $logDirectory ('naming_{0}_{1}.jsonl' -f (Get-Date -Format yyyyMMdd_HHmmss), [guid]::NewGuid().ToString('N').Substring(0,8))
try {
    $python = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    & $python (Join-Path $PSScriptRoot 'src\rename_stage.py') --result $ResultFile --config $ConfigPath |
        Tee-Object -FilePath $log | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw '名称补全程序异常退出，已有处理结果保留。' }
    $result = Get-Content -LiteralPath $ResultFile -Raw -Encoding utf8 | ConvertFrom-Json
    # Persist the whole batch so an outer package's additional RJ works are retained.
    if ($result.PSObject.Properties['source_archives'] -and @($result.source_archives).Count -gt 0) {
        foreach ($parent in @($result.final_directories | ForEach-Object { Split-Path -LiteralPath $_ } | Select-Object -Unique)) {
            $mapPath = Join-Path $parent '.rj-name-map.json'
            $entries = @()
            if (Test-Path -LiteralPath $mapPath) {
                $entries = @(Get-Content -LiteralPath $mapPath -Raw -Encoding utf8 | ConvertFrom-Json |
                    Where-Object { $_.result_file -ne $ResultFile })
            }
            $entry = [PSCustomObject]@{ sources=@($result.source_archives); directories=@($result.final_directories); result_file=$ResultFile }
            $temporaryMap = "$mapPath.$([guid]::NewGuid().ToString('N')).tmp"
            ConvertTo-Json -InputObject (@($entry) + $entries) -Depth 8 | Out-File -LiteralPath $temporaryMap -Encoding utf8
            Move-Item -LiteralPath $temporaryMap -Destination $mapPath -Force
        }
    }
    $pending = @($result.naming_results | Where-Object status -eq 'pending')
    Write-Host "名称补全：待补全 $($pending.Count) 项；日志：$log"
    if ($pending.Count -gt 0) { exit 10 }
    exit 0
} catch {
    Write-Host "名称补全未完成：$($_.Exception.Message)" -ForegroundColor Yellow
    exit 10
}
