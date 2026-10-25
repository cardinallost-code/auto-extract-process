#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath,
    [switch]$Run,
    [switch]$ExtractToSource,
    [string]$OutputRoot,
    [ValidateRange(1, 8)]
    [int]$MaxParallelProjects = 4,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'src\archive-identity.ps1')

$extractor = Join-Path $PSScriptRoot 'extract.ps1'
$fileProcessor = Join-Path $PSScriptRoot 'file-process.ps1'

function Get-OptionalPropertyItems($Object, [string]$Name) {
    if ($null -eq $Object) { return @() }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

function Merge-ExtractionJobResults([object[]]$Jobs, [int]$ExpectedCount) {
    $directories = [Collections.Generic.List[string]]::new()
    $sources = [Collections.Generic.List[object]]::new()
    $failures = [Collections.Generic.List[object]]::new()
    $deletedArchives = [Collections.Generic.List[string]]::new()
    $preservedPackaging = [Collections.Generic.List[string]]::new()
    $failureCount = 0
    $fatalCount = 0
    foreach ($job in $Jobs) {
        try {
            if ($null -eq $job.exit_code -or $job.exit_code -notin @(0, 2)) {
                throw "解压任务异常退出：$($job.exit_code)"
            }
            $part = Get-Content -LiteralPath $job.result_file -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $part -or $part -isnot [PSCustomObject] -or
                $null -eq $part.PSObject.Properties['final_directories'] -or
                $null -eq $part.PSObject.Properties['failure_count'] -or
                ($part.failure_count -isnot [long] -and $part.failure_count -isnot [int])) {
                throw '解压结果清单缺少有效的目录或失败计数'
            }
            if ($part.failure_count -lt 0 -or $part.final_directories -isnot [array] -or
                @($part.final_directories | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count) {
                throw '解压结果清单字段格式错误'
            }
            foreach ($directory in $part.final_directories) { $directories.Add($directory) }
            foreach ($source in @(Get-OptionalPropertyItems $part 'source_archives')) { $sources.Add($source) }
            foreach ($failure in @(Get-OptionalPropertyItems $part 'failed_archives')) { $failures.Add($failure) }
            foreach ($path in @(Get-OptionalPropertyItems $part 'deleted_archives')) { $deletedArchives.Add($path) }
            foreach ($path in @(Get-OptionalPropertyItems $part 'preserved_packaging')) { $preservedPackaging.Add($path) }
            # A warning exit must not become success because its manifest says zero.
            $failureCount += [Math]::Max($part.failure_count, $(if ($job.exit_code -eq 2) { 1 } else { 0 }))
        } catch {
            $fatalCount++
            $failureCount++
            foreach ($path in $job.paths) {
                $failures.Add([PSCustomObject]@{ archive=[string]$path; status='fatal_job'; reason=$_.Exception.Message })
            }
        }
    }
    if ($Jobs.Count -ne $ExpectedCount) {
        $fatalCount++
        $failureCount++
        $failures.Add([PSCustomObject]@{ archive='并行任务'; status='missing_job'; reason='部分解压任务未返回状态' })
    }
    [PSCustomObject]@{
        completed = (Get-Date).ToString('o')
        success = ($failureCount -eq 0)
        failure_count = $failureCount
        final_directories = @($directories | Sort-Object -Unique)
        source_archives = @($sources.ToArray())
        deleted_archives = @($deletedArchives | Sort-Object -Unique)
        preserved_packaging = @($preservedPackaging | Sort-Object -Unique)
        failed_archives = @($failures | Sort-Object archive, status -Unique)
        exit_code = $(if ($fatalCount -gt 0) { 1 } elseif ($failureCount -gt 0) { 2 } else { 0 })
    }
}

if (-not $Run) {
    Write-Host '一键流水线预演：当前只检查解压计划；文件处理会在解压成功后自动执行。' -ForegroundColor Cyan
    if ($ExtractToSource) {
        & $extractor -InputPath $InputPath -ExtractToSource -ConfigPath $ConfigPath
    } elseif ($OutputRoot) {
        & $extractor -InputPath $InputPath -OutputRoot $OutputRoot -ConfigPath $ConfigPath
    } else {
        & $extractor -InputPath $InputPath -ConfigPath $ConfigPath
    }
    exit $LASTEXITCODE
}

$resultDirectory = Join-Path $PSScriptRoot 'work\pipeline_results'
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
$resultFile = Join-Path $resultDirectory ("extract_{0}_{1}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), [guid]::NewGuid().ToString('N').Substring(0,8))

Write-Host '========== 阶段 1/3：递归解压 ==========' -ForegroundColor Cyan

# 同一 RJ 的分卷、重复下载或包装包必须留在同一串行任务中；不同 RJ 才并行。
$projectGroups = @(Get-ArchiveProjectGroups $InputPath)

if ($projectGroups.Count -gt 1 -and $MaxParallelProjects -gt 1) {
    $throttle = [Math]::Min($MaxParallelProjects, $projectGroups.Count)
    Write-Host "并行项目：$($projectGroups.Count) 组；同时运行：$throttle" -ForegroundColor Cyan
    $partDirectory = Join-Path $resultDirectory ([IO.Path]::GetFileNameWithoutExtension($resultFile) + '_parts')
    New-Item -ItemType Directory -Path $partDirectory -Force | Out-Null

    $jobOutput = @(
        $projectGroups | ForEach-Object -Parallel {
            $group = $_
            $partResult = Join-Path $using:partDirectory ("{0}_{1}.json" -f `
                ($group.Key -replace '[^A-Za-z0-9_-]', '_'), [guid]::NewGuid().ToString('N').Substring(0,8))
            Write-Host "[$($group.Key)] 开始：$($group.Paths.Count) 项" -ForegroundColor Cyan

            try {
                if ($using:ExtractToSource) {
                    & $using:extractor -InputPath @($group.Paths) -Run -ExtractToSource `
                        -ResultFile $partResult -ConfigPath $using:ConfigPath
                } elseif ($using:OutputRoot) {
                    & $using:extractor -InputPath @($group.Paths) -Run -OutputRoot $using:OutputRoot `
                        -ResultFile $partResult -ConfigPath $using:ConfigPath
                } else {
                    & $using:extractor -InputPath @($group.Paths) -Run `
                        -ResultFile $partResult -ConfigPath $using:ConfigPath
                }
                $code = $LASTEXITCODE
            } catch {
                Write-Warning "[$($group.Key)] 解压任务异常：$($_.Exception.Message)"
                $code = 1
            }
            Write-Host "[$($group.Key)] 结束：退出代码 $code" `
                -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Yellow' })
            [PSCustomObject]@{
                pipeline_job_result = $true
                key = $group.Key
                exit_code = $code
                result_file = $partResult
                paths = @($group.Paths)
            }
        } -ThrottleLimit $throttle
    )

    $jobResults = @($jobOutput | Where-Object {
        $_ -and $_.PSObject.Properties['pipeline_job_result'] -and $_.pipeline_job_result -eq $true
    })
    $merged = Merge-ExtractionJobResults -Jobs $jobResults -ExpectedCount $projectGroups.Count
    $merged | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $resultFile -Encoding utf8
    $extractExitCode = $merged.exit_code
} else {
    Write-Host '并行项目：1 组；使用串行递归解压' -ForegroundColor DarkGray
    if ($ExtractToSource) {
        & $extractor -InputPath $InputPath -Run -ExtractToSource -ResultFile $resultFile -ConfigPath $ConfigPath
    } elseif ($OutputRoot) {
        & $extractor -InputPath $InputPath -Run -OutputRoot $OutputRoot -ResultFile $resultFile -ConfigPath $ConfigPath
    } else {
        & $extractor -InputPath $InputPath -Run -ResultFile $resultFile -ConfigPath $ConfigPath
    }
    $extractExitCode = $LASTEXITCODE
}
if ($extractExitCode -notin @(0, 2)) {
    Write-Host "解压阶段失败，文件处理不会启动。退出代码：$extractExitCode" -ForegroundColor Red
    exit $extractExitCode
}
if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
    Write-Host '解压阶段没有生成结果清单，文件处理不会启动。' -ForegroundColor Red
    exit 3
}

$result = Get-Content -LiteralPath $resultFile -Raw -Encoding utf8 | ConvertFrom-Json
$finalDirectories = @($result.final_directories | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
$failedArchives = @(Get-OptionalPropertyItems $result 'failed_archives')
function Show-FailedArchives {
    if ($failedArchives.Count -eq 0) { return }
    Write-Host ''
    Write-Host '========== 最终失败压缩包清单 ==========' -ForegroundColor Red
    foreach ($failedArchive in $failedArchives) {
        Write-Host "  $($failedArchive.archive)" -ForegroundColor Red
        Write-Host "    原因：$($failedArchive.reason)" -ForegroundColor Yellow
    }
}
if ($finalDirectories.Count -eq 0) {
    Write-Host '本次解压没有产生可处理的作品目录，文件处理不会启动。' -ForegroundColor Yellow
    exit 4
}

$extractPartiallyFailed = ($extractExitCode -eq 2)
if ($extractPartiallyFailed) {
    Write-Host ''
    Write-Host '解压阶段有部分项目失败；成功解压的作品将继续执行文件处理。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '========== 阶段 2/3：文件处理 ==========' -ForegroundColor Cyan
Write-Host "本次作品目录：$($finalDirectories.Count)"
$finalDirectories | ForEach-Object { Write-Host "  $_" }
& $fileProcessor -InputPath $finalDirectories -Run -ConfigPath $ConfigPath
$processExitCode = $LASTEXITCODE
if ($processExitCode -ne 0) {
    Write-Host "文件处理阶段未完全成功。退出代码：$processExitCode" -ForegroundColor Red
    Show-FailedArchives
    exit $processExitCode
}

Write-Host ''
Write-Host '========== 阶段 3/3：作品名称补全 ==========' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'rename-stage.ps1') -ResultFile $resultFile -ConfigPath $ConfigPath
$namingExitCode = $LASTEXITCODE
if ($namingExitCode -ne 0) {
    Write-Host '解压和文件处理完成，部分作品名称待补全。可单独重试第三阶段。' -ForegroundColor Yellow
}

if ($extractPartiallyFailed) {
    Show-FailedArchives
    Write-Host '流水线已处理所有成功解压的作品，但仍有压缩包解压失败；详情见上方清单。' -ForegroundColor Yellow
    exit 2
}

if ($namingExitCode -ne 0) { exit $namingExitCode }
Write-Host '一键流水线全部完成。' -ForegroundColor Green
exit 0
