#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath,
    [switch]$Run,
    [switch]$ExtractToSource,
    [string]$OutputRoot,
    [string]$ResultFile,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'src\archive-cleanup.ps1')
. (Join-Path $PSScriptRoot 'src\bandizip.ps1')
. (Join-Path $PSScriptRoot 'src\archive-encoding.ps1')
. (Join-Path $PSScriptRoot 'src\archive-identity.ps1')
. (Join-Path $PSScriptRoot 'src\extraction-lifecycle.ps1')

trap {
    Write-Host "[内部错误] $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed }
    throw
}

function Stop-WithError([string]$Message, [int]$Code = 1) {
    Write-Host "[错误] $Message" -ForegroundColor Red
    exit $Code
}

function Find-7Zip {
    $command = Get-Command 7z.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }

    foreach ($candidate in @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe",
        "C:\7-Zip\7z.exe"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-SignatureKind([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, "Open", "Read", "ReadWrite")
        try {
            $buffer = [byte[]]::new(8)
            $count = $stream.Read($buffer, 0, $buffer.Length)
        }
        finally { $stream.Dispose() }

        if ($count -ge 6 -and ($buffer[0..5] -join ',') -eq '55,122,188,175,39,28') { return "7z" }
        if ($count -ge 4 -and $buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B -and
            $buffer[2] -in @(0x03, 0x05, 0x07) -and $buffer[3] -in @(0x04, 0x06, 0x08)) { return "zip" }
        if ($count -ge 7 -and [Text.Encoding]::ASCII.GetString($buffer, 0, 4) -eq "Rar!" -and
            $buffer[4] -eq 0x1A -and $buffer[5] -eq 0x07) { return "rar" }
        if ($count -ge 2 -and $buffer[0] -eq 0x4D -and $buffer[1] -eq 0x5A) { return "pe/sfx" }
        if ($count -ge 2 -and $buffer[0] -eq 0x1F -and $buffer[1] -eq 0x8B) { return "gzip" }
    }
    catch { return "unreadable" }
    return "unknown"
}

function Test-IsRealSfx([string]$Path) {
    # 7-Zip also lists raw PE sections. Successful listing alone is not proof of SFX.
    $listing = Invoke-7ZipCapture @('l', '-slt', '-bd', '-p-', '--', $Path)
    $header = (($listing.Output -join "`n") -split '(?m)^----------', 2)[0]
    return [bool]($header -match '(?im)^Type = (7z|Rar|Rar5|zip)\s*$')
}

function Test-IsArchiveCandidate([IO.FileInfo]$File) {
    $name = $File.Name
    if ($File.Extension -match '(?i)^\.(dll|sys|ocx|cpl|scr)$') { return $false }
    $signature = Get-SignatureKind $File.FullName
    if ($signature -eq 'pe/sfx') { return Test-IsRealSfx $File.FullName }
    # .ra is sometimes used as a disguised archive suffix. RealAudio files using
    # the same suffix must not be sent to the extractor, so require archive magic.
    if ($File.Extension -in @('.ra','.zi')) { return $signature -in @('7z','zip','rar','gzip') }
    # Office/OpenDocument 等文档虽然内部是 ZIP 容器，但不是需要递归展开的作品压缩包。
    if ($File.Extension -match '(?i)^\.(docx|xlsx|pptx|docm|xlsm|pptm|odt|ods|odp|epub|apk|jar)$') { return $false }
    if ($name -match '(?i)\.(zip|rar|7z|tar|tgz|gz|bz2|xz)$') { return $true }
    if ($name -match '(?i)\.(7z|zip)\.0*1$') { return $true }
    if ($name -match '(?i)\.part0*1\.rar$') { return $true }
    # 任何未知、伪装或乱改的扩展名都回退到真实文件头检查。
    $signature = Get-SignatureKind $File.FullName
    return $signature -in @('7z','zip','rar','gzip')
}

function Repair-ArchiveExtension([IO.FileInfo]$File) {
    if (-not $Run) { return $File }
    $signature = Get-SignatureKind $File.FullName
    $canonicalExtension = switch ($signature) {
        '7z' { '.7z' }
        'zip' { '.zip' }
        'rar' { '.rar' }
        'gzip' { '.gz' }
        'pe/sfx' { '.exe' }
        default { $null }
    }
    if (-not $canonicalExtension) { return $File }

    $currentExtension = $File.Extension.ToLowerInvariant()
    $target = $null
    if (-not $currentExtension) {
        $target = "$($File.FullName)$canonicalExtension"
    }
    elseif ($currentExtension -in @('.r','.ra','.zi','.e')) {
        $target = [IO.Path]::ChangeExtension($File.FullName, $canonicalExtension)
    }
    if (-not $target) { return $File }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Write-Host "[警告] 扩展名补全目标已存在，优先处理规范文件并保留原文件：$target" `
            -ForegroundColor Yellow
        return Get-Item -LiteralPath $target
    }
    Move-Item -LiteralPath $File.FullName -Destination $target -ErrorAction Stop
    Write-Host "已根据文件头补全扩展名：$target" -ForegroundColor DarkGray
    return Get-Item -LiteralPath $target
}

function Get-ArchiveBaseName([string]$Name) {
    $result = $Name
    $result = $result -replace '(?i)\.(7z|zip)\.0*1$', ''
    $result = $result -replace '(?i)\.part0*1\.(rar|exe|r|e)$', ''
    $result = $result -replace '(?i)\.(zip|zi|rar|ra|7z|tar|tgz|gz|bz2|xz|exe)$', ''
    if ($result -match '^(\d{7,8})\.[^.]+$') { $result = $Matches[1] }
    if (-not $result) { $result = "archive" }
    return ($result -replace '[<>:"/\\|?*]', '_')
}

function Commit-FinalRjDirectory([string]$PayloadDirectory, [string]$FinalDirectory, [string]$FinalArchive, [bool]$AllowExisting = $false) {
    $commit = Merge-ExtractionPayload $PayloadDirectory $FinalDirectory $FinalArchive
    if (-not $commit.Success) { return $commit }
    [PSCustomObject]@{
        completed=(Get-Date).ToString('o'); final_archive=[IO.Path]::GetFileName($FinalArchive)
        normalized_to_rj=[bool](Get-RjCode $FinalDirectory); committed=$true
        duplicate_files=$commit.DuplicateCount
    } | ConvertTo-Json | Out-File -LiteralPath (Join-Path $FinalDirectory '.extract_complete.json') -Encoding utf8
    return $commit
}

function Get-PasswordCandidates([string]$PasswordFile) {
    $values = [Collections.Generic.List[object]]::new()
    $seenPasswords = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $values.Add($null)
    if (Test-Path -LiteralPath $PasswordFile -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $PasswordFile -Encoding utf8) {
            if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.TrimStart().StartsWith('#')) {
                # Keep literal whitespace passwords valid, while also tolerating
                # accidental padding copied into the password file.
                foreach ($candidate in @($line, $line.Trim())) {
                    if ($seenPasswords.Add($candidate)) { $values.Add($candidate) }
                }
            }
        }
    }
    return @($values)
}

function Get-RjPasswordCandidates([string]$ArchivePath) {
    if (-not $config.extraction.rj_password.enabled) { return @() }

    $result = [Collections.Generic.List[string]]::new()
    foreach ($pathRjCode in @(Get-RjCodesFromPath $ArchivePath)) {
        $result.Add($pathRjCode.ToUpperInvariant())
        $result.Add($pathRjCode.ToLowerInvariant())
    }

    $resolver = Join-Path $PSScriptRoot $config.extraction.rj_password.resolver
    $cachePath = $config.extraction.rj_password.cache_db
    if (-not (Test-Path -LiteralPath $resolver -PathType Leaf) -or
        -not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        return @($result | Select-Object -Unique)
    }

    $python = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $python) { return @($result | Select-Object -Unique) }

    $arguments = @(
        $resolver,
        "--text", $ArchivePath,
        "--cache", $cachePath,
        "--limit", [string]$config.extraction.rj_password.max_candidates,
        "--timeout", [string]$config.extraction.rj_password.online_timeout_seconds
    )
    if ($config.extraction.rj_password.online_fallback) { $arguments += "--online" }

    try {
        $json = & $python.Source @arguments 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $json) { return @($result | Select-Object -Unique) }
        $codes = @($json | ConvertFrom-Json -ErrorAction Stop)
        foreach ($code in $codes) {
            $normalized = [string]$code
            if ($normalized -match '^RJ\d{8}$') {
                $result.Add($normalized.ToUpperInvariant())
                $result.Add($normalized.ToLowerInvariant())
            }
        }
        return @($result | Select-Object -Unique)
    }
    catch { return @($result | Select-Object -Unique) }
}

function Merge-PasswordCandidates([object[]]$RjPasswords, [object[]]$ConfiguredPasswords) {
    $result = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $result.Add($null)
    foreach ($password in @($RjPasswords) + @($ConfiguredPasswords)) {
        if ($null -eq $password) { continue }
        $value = [string]$password
        if ($seen.Add($value)) { $result.Add($value) }
    }
    return @($result)
}

function Invoke-7ZipCapture([string[]]$Arguments) {
    $output = & $script:sevenZip @Arguments 2>&1
    [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
}

function Get-ArchiveNameCodePageArguments([string]$Archive) {
    $codePage = Get-SelectedArchiveCodePage $Archive
    if ($codePage -le 0) { return @() }
    return @("-mcp=$codePage")
}

function Get-RjPasswordCandidatesFromListing([string]$Archive) {
    $arguments = @('l', '-slt', '-bd', '-p-') + @(Get-ArchiveNameCodePageArguments $Archive) + @('--', $Archive)
    $listing = Invoke-7ZipCapture $arguments
    if ($listing.ExitCode -ne 0) { return @() }
    $result = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $listing.Output) {
        foreach ($match in [regex]::Matches([string]$line, '(?i)RJ\D{0,3}(\d{8})')) {
            $code = "RJ$($match.Groups[1].Value)"
            foreach ($candidate in @($code.ToUpperInvariant(), $code.ToLowerInvariant())) {
                if ($seen.Add($candidate)) { $result.Add($candidate) }
            }
        }
    }
    return @($result)
}

function Find-ArchivePassword([string]$Archive, [object[]]$Passwords) {
    $encryptedPayloadDetected = $false
    for ($index = 0; $index -lt @($Passwords).Count; $index++) {
        $password = $Passwords[$index]
        $passwordArgument = if ($null -eq $password) { "-p-" } else { "-p$password" }
        # Listing an archive with visible headers does not validate encrypted file data.
        # Verify encrypted payloads before extracting, or each wrong password can write
        # a multi-gigabyte partial file before Bandizip reports a CRC failure.
        $listArguments = @("l", "-slt", "-bd", $passwordArgument) + @(Get-ArchiveNameCodePageArguments $Archive) + @("--", $Archive)
        $test = Invoke-7ZipCapture $listArguments
        if ($test.ExitCode -eq 0) {
            $encryptedPayload = @($test.Output | Where-Object { [string]$_ -match '^Encrypted = \+\s*$' }).Count -gt 0
            if ($encryptedPayload) {
                $encryptedPayloadDetected = $true
                $verifyArguments = @("t", "-bd", $passwordArgument) + @(Get-ArchiveNameCodePageArguments $Archive) + @("--", $Archive)
                $verification = Invoke-7ZipCapture $verifyArguments
                if ($verification.ExitCode -ne 0) { continue }
            }
            return [PSCustomObject]@{ Found = $true; Password = $password; PasswordIndex = $index }
        }
    }
    return [PSCustomObject]@{ Found = $false; Password = $null; PasswordIndex = -1; EncryptedPayloadDetected = $encryptedPayloadDetected }
}

function Remove-CoveredArchiveCandidates([object[]]$Candidates) {
    # PowerShell 在空集合、单项集合和管道返回值之间会改变对象形态。
    # 统一重新解析为真实文件对象，避免 $null、字符串或嵌套数组进入分卷判断。
    [IO.FileInfo[]]$validCandidates = @(
        foreach ($candidate in @($Candidates)) {
            if ($null -eq $candidate) { continue }
            if ($candidate -is [IO.FileInfo]) {
                $candidate
                continue
            }
            if ($candidate -is [string] -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                Get-Item -LiteralPath $candidate
                continue
            }
            if ($candidate -is [System.Collections.IEnumerable] -and $candidate -isnot [string]) {
                foreach ($nestedCandidate in $candidate) {
                    if ($nestedCandidate -is [IO.FileInfo]) { $nestedCandidate }
                    elseif ($nestedCandidate -is [string] -and (Test-Path -LiteralPath $nestedCandidate -PathType Leaf)) {
                        Get-Item -LiteralPath $nestedCandidate
                    }
                }
            }
        }
    )
    if (@($validCandidates).Count -eq 0) { return @() }

    $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # 同组 part 分卷只从第 1 卷启动，后续卷由 7-Zip 自动读取。
    foreach ($candidate in $validCandidates) {
        if ($candidate.Name -match '(?i)^.*\.part0*(\d+)\.(?:rar|exe)$' -and [int]$Matches[1] -gt 1) {
            [void]$covered.Add($candidate.FullName)
        }
    }
    foreach ($outer in $validCandidates) {
        $outerDirectory = Split-Path -LiteralPath $outer.FullName
        $outerBase = Get-ArchiveBaseName $outer.Name
        $expandedDirectory = Join-Path $outerDirectory $outerBase
        $expandedPrefix = $expandedDirectory.TrimEnd('\') + '\'
        foreach ($candidate in $validCandidates) {
            if ($candidate.FullName -ne $outer.FullName -and
                $candidate.FullName.StartsWith($expandedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$covered.Add($candidate.FullName)
            }
        }
    }
    return @($validCandidates | Where-Object { -not $covered.Contains($_.FullName) })
}

function New-NestedArchiveJob([IO.FileInfo]$Nested, $ParentJob, [string]$TopOutput) {
    $childRjCode = Get-RjCode $Nested.FullName
    if (-not $childRjCode) { $childRjCode = $ParentJob.RjCode }
    $finalBase = [IO.Directory]::GetParent([IO.Path]::GetFullPath($ParentJob.FinalDirectory)).FullName
    $childFinalDirectory = Join-Path $finalBase $(if ($childRjCode) { $childRjCode } else { Get-ArchiveBaseName $Nested.Name })
    return [PSCustomObject]@{
        Path = $Nested.FullName
        Depth = ($ParentJob.Depth + 1)
        RjCode = $childRjCode
        FinalDirectory = $childFinalDirectory
        TopOutput = $TopOutput
    }
}

function Get-ArchiveSafety([string]$Archive, $Password, [long]$MaxBytes, [int]$MaxFiles) {
    $passwordArgument = if ($null -eq $Password) { "-p-" } else { "-p$Password" }
    $listArguments = @("l", "-slt", "-bd", $passwordArgument) + @(Get-ArchiveNameCodePageArguments $Archive) + @("--", $Archive)
    $listing = Invoke-7ZipCapture $listArguments
    if ($listing.ExitCode -ne 0) {
        return [PSCustomObject]@{ Safe = $false; Reason = "无法读取文件清单"; Files = 0; Bytes = 0L }
    }

    $afterDivider = $false
    $fileCount = 0
    $totalBytes = 0L
    foreach ($lineObject in $listing.Output) {
        $line = [string]$lineObject
        if ($line -match '^-{5,}$') { $afterDivider = $true; continue }
        if (-not $afterDivider) { continue }

        if ($line -match '^Path = (.*)$') {
            $entry = $Matches[1]
            $fileCount++
            if ([IO.Path]::IsPathRooted($entry) -or $entry -match '(^|[\\/])\.\.([\\/]|$)' -or
                $entry -match '^[\\/]{1,2}') {
                return [PSCustomObject]@{ Safe = $false; Reason = "包含越界路径：$entry"; Files = $fileCount; Bytes = $totalBytes }
            }
        }
        elseif ($line -match '^Size = ([0-9]+)$') {
            $totalBytes += [long]$Matches[1]
        }

        if ($fileCount -gt $MaxFiles) {
            return [PSCustomObject]@{ Safe = $false; Reason = "文件数量超过限制 $MaxFiles"; Files = $fileCount; Bytes = $totalBytes }
        }
        if ($MaxBytes -gt 0 -and $totalBytes -gt $MaxBytes) {
            return [PSCustomObject]@{ Safe = $false; Reason = "展开体积超过限制"; Files = $fileCount; Bytes = $totalBytes }
        }
    }
    return [PSCustomObject]@{ Safe = $true; Reason = ""; Files = $fileCount; Bytes = $totalBytes }
}

function Write-Result($Result) {
    $Result | ConvertTo-Json -Compress -Depth 5 |
        Out-File -LiteralPath $script:logPath -Encoding utf8 -Append
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Stop-WithError "找不到配置文件：$ConfigPath"
}
if ($ExtractToSource -and $OutputRoot) {
    Stop-WithError "-ExtractToSource 和 -OutputRoot 不能同时使用"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
$script:sevenZip = Find-7Zip
if (-not $script:sevenZip) { Stop-WithError "未找到 7-Zip 命令行程序 7z.exe" }
$script:extractionEngine = if ($config.extraction.PSObject.Properties['engine']) { [string]$config.extraction.engine } else { 'bandizip' }
if ($script:extractionEngine -notin @('bandizip', '7zip')) { Stop-WithError '解压引擎仅支持 bandizip 或 7zip' }
if ($script:extractionEngine -eq 'bandizip') {
    $configuredBandizip = if ($config.extraction.PSObject.Properties['bandizip_path']) { [string]$config.extraction.bandizip_path } else { '' }
    $script:bandizip = Find-Bandizip $configuredBandizip
}
$resolvedInputs = [Collections.Generic.List[string]]::new()
foreach ($path in $InputPath) {
    if (-not (Test-Path -LiteralPath $path)) { Stop-WithError "输入不存在：$path" }
    $resolved = (Resolve-Path -LiteralPath $path).Path
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        $resolved = (Repair-ArchiveExtension (Get-Item -LiteralPath $resolved)).FullName
    }
    if (-not $resolvedInputs.Contains($resolved)) { $resolvedInputs.Add($resolved) }
}
if (@($resolvedInputs).Count -eq 0) { Stop-WithError "没有有效输入" }
$archiveConfig = $config.extraction
$passwordFile = if ([IO.Path]::IsPathRooted($archiveConfig.password_file)) {
    $archiveConfig.password_file
} else { Join-Path $PSScriptRoot $archiveConfig.password_file }
$configuredPasswords = @(Get-PasswordCandidates $passwordFile)
$maxDepth = [int]$archiveConfig.nested_max_depth
$maxFiles = [int]$archiveConfig.max_file_count
$maxExpandedSizeGb = [double]$archiveConfig.max_expanded_size_gb
$maxBytes = if ($maxExpandedSizeGb -le 0) { 0L } else { [long]($maxExpandedSizeGb * 1GB) }

if (-not $ExtractToSource -and -not $OutputRoot) {
    if (@($resolvedInputs).Count -eq 1) {
        $baseDirectory = if (Test-Path -LiteralPath $resolvedInputs[0] -PathType Container) {
            $resolvedInputs[0]
        } else { Split-Path -LiteralPath $resolvedInputs[0] }
        $OutputRoot = Join-Path $baseDirectory "_extracted"
    }
    else {
        $OutputRoot = Join-Path $PSScriptRoot "output\extracted"
    }
}
if ($OutputRoot) { $OutputRoot = [IO.Path]::GetFullPath($OutputRoot) }

$logDirectory = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$script:logPath = Join-Path $logDirectory ("extract_{0}_{1}.jsonl" -f `
    (Get-Date -Format "yyyyMMdd_HHmmss"), [guid]::NewGuid().ToString('N').Substring(0,8))

$initialFiles = @(
    foreach ($resolvedInput in $resolvedInputs) {
        if (Test-Path -LiteralPath $resolvedInput -PathType Container) {
            Get-ChildItem -LiteralPath $resolvedInput -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { Test-IsArchiveCandidate $_ }
        }
        else {
            $item = Get-Item -LiteralPath $resolvedInput
            # 用户直接拖入的文件一律作为压缩包起点，由 7-Zip 做最终格式判定。
            # 这样未知扩展名、无扩展名和伪装分卷不会在入口处被静默忽略。
            $item
        }
    }
)
$allCandidateCount = @($initialFiles).Count
$sourceArchiveSnapshots = @(
    $sourceFiles = @($initialFiles | ForEach-Object {
        $_
        Get-ArchivePartFiles $_.FullName
    } | Sort-Object FullName -Unique)
    foreach ($sourceFile in $sourceFiles) {
        [PSCustomObject]@{ path=$sourceFile.FullName; size=[string]$sourceFile.Length; modified=[string]$sourceFile.LastWriteTimeUtc.Ticks }
    }
)
$initialFiles = @(Remove-CoveredArchiveCandidates $initialFiles)
$coveredCandidateCount = $allCandidateCount - @($initialFiles).Count

if (@($initialFiles).Count -eq 0) { Stop-WithError "没有发现可处理的压缩包或拖入文件" 2 }

$queue = [Collections.Generic.Queue[object]]::new()
foreach ($file in $initialFiles) {
    $rjCode = Get-RjCode $file.FullName
    $finalBase = if ($ExtractToSource) { Split-Path -LiteralPath $file.FullName } else { $OutputRoot }
    $finalDirectory = Join-Path $finalBase $(if ($rjCode) { $rjCode } else { Get-ArchiveBaseName $file.Name })
    if ($finalDirectory.Equals($file.FullName,[StringComparison]::OrdinalIgnoreCase)) { $finalDirectory += '_extracted' }
    $queue.Enqueue([PSCustomObject]@{
        Path=$file.FullName; Depth=0; RjCode=$rjCode
        FinalDirectory=$finalDirectory; TopOutput=$null
    })
}
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$successCount = 0
$failureCount = 0
$planCount = 0
$maxObservedDepth = 0
$remainingNestedCount = 0
$finalDirectories = [Collections.Generic.List[string]]::new()
$completedNumericWrappers = [Collections.Generic.List[object]]::new()
$packagingRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$archiveDeletionCandidates = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$deletedSourceArchives = [Collections.Generic.List[string]]::new()
$preservedPackaging = [Collections.Generic.List[string]]::new()

Write-Host ""
Write-Host "解压阶段：$(if ($Run) { '执行' } else { '安全预演' })" -ForegroundColor Cyan
Write-Host "输入：$(@($resolvedInputs).Count) 项"
$resolvedInputs | ForEach-Object { Write-Host "  $_" }
Write-Host "输出：$(if ($ExtractToSource) { '各压缩包原目录下的同名文件夹' } else { $OutputRoot })"
Write-Host "安全预检 7-Zip：$script:sevenZip"
if ($script:extractionEngine -eq 'bandizip') { Write-Host "默认解压 Bandizip：$script:bandizip" }
else { Write-Host "默认解压：7-Zip" }
Write-Host "ZIP 文件名解码：$($config.extraction.zip_filename_code_page)（932 为日文）"
Write-Host "固定密码候选：$(@($configuredPasswords).Count - 1) 个（不写入日志）"
Write-Host "RJ 动态密码：$(if ($archiveConfig.rj_password.enabled) { '启用' } else { '禁用' })"
Write-Host "展开体积上限：$(if ($maxBytes -le 0) { '未限制' } else { "$maxExpandedSizeGb GiB" })"
Write-Host "已展开目录覆盖的内层包：$coveredCandidateCount 个（不作为独立起点）"
Write-Host ""

while ($queue.Count -gt 0) {
    $job = $queue.Dequeue()
    $archive = [IO.Path]::GetFullPath($job.Path)
    $maxObservedDepth = [Math]::Max($maxObservedDepth, [int]$job.Depth)
    if (-not $seen.Add($archive)) { continue }
    if ($job.Depth -gt $maxDepth) { continue }

    $lockKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($job.FinalDirectory.ToLowerInvariant())))
    $workLock=[Threading.Mutex]::new($false,"Local\ArchiveWork_$lockKey")
    $lockHeld=$false
    try {
        try { $lockHeld=$workLock.WaitOne(120000) } catch [Threading.AbandonedMutexException] { $lockHeld=$true }
        if (-not $lockHeld) { throw "等待同作品任务完成超时：$($job.FinalDirectory)" }

    if ($Run -and $job.Depth -eq 0) {
        $receiptRoot = if ($ExtractToSource) { Split-Path -LiteralPath $archive } else { $OutputRoot }
        $receiptPath = Join-Path $receiptRoot '.rj-name-map.json'
        $reused = $false
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            try {
                foreach ($receipt in @(Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json)) {
                    if (@($receipt.sources | Where-Object path -eq $archive).Count -eq 0) { continue }
                    $validReceipt = @($receipt.directories).Count -gt 0
                    # A name-map receipt can be written after a partial pipeline run.
                    # It must not hide archives that failed during extraction.
                    if (-not $receipt.result_file -or -not (Test-Path -LiteralPath $receipt.result_file -PathType Leaf)) {
                        $validReceipt = $false
                    } else {
                        $receiptResult = Get-Content -LiteralPath $receipt.result_file -Raw -Encoding utf8 | ConvertFrom-Json
                        if (-not $receiptResult.success -or [int]$receiptResult.failure_count -ne 0 -or
                            @($receiptResult.failed_archives | Where-Object { $_ }).Count -gt 0) { $validReceipt = $false }
                    }
                    foreach ($source in $receipt.sources) {
                        if (-not (Test-Path -LiteralPath $source.path -PathType Leaf)) { $validReceipt=$false; break }
                        $sourceInfo = Get-Item -LiteralPath $source.path
                        if ([string]$sourceInfo.Length -ne $source.size -or [string]$sourceInfo.LastWriteTimeUtc.Ticks -ne $source.modified) { $validReceipt=$false; break }
                    }
                    foreach ($directory in $receipt.directories) {
                        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { $validReceipt=$false; break }
                    }
                    if (-not $validReceipt) { continue }
                    foreach ($directory in $receipt.directories) {
                        if (-not $finalDirectories.Contains($directory)) { $finalDirectories.Add($directory) }
                    }
                    Write-Host "跳过：已识别名称补全后的完成结果：$archive" -ForegroundColor DarkGray
                    Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; status='skipped_named_batch'; directories=@($receipt.directories) })
                    $reused=$true
                    break
                }
            } catch { Write-Host "名称映射不可用，继续常规检查：$($_.Exception.Message)" -ForegroundColor Yellow }
        }
        if ($reused) {
            foreach ($part in @(Get-ArchivePartFiles $archive)) {
                $archiveDeletionCandidates[$part.FullName]=[PSCustomObject]@{Path=$part.FullName;Size=$part.Length;Modified=$part.LastWriteTimeUtc.Ticks;Depth=0}
            }
            continue
        }
    }

    if ($Run) {
        foreach ($part in @(Get-ArchivePartFiles $archive)) {
            if (-not $archiveDeletionCandidates.ContainsKey($part.FullName)) {
                $archiveDeletionCandidates[$part.FullName]=[PSCustomObject]@{
                    Path=$part.FullName; Size=$part.Length; Modified=$part.LastWriteTimeUtc.Ticks; Depth=$job.Depth
                }
            }
        }
    }
    $signature = Get-SignatureKind $archive
    Write-Host "检查：$archive [$signature]"
    if ($signature -eq 'pe/sfx' -and -not (Test-IsRealSfx $archive)) {
        Write-Host '  拒绝：普通可执行程序，不是真实自解压包；原文件保留。' -ForegroundColor Yellow
        $failureCount++
        Write-Result ([PSCustomObject]@{ archive=$archive; status='rejected_plain_pe' })
        continue
    }

    $rjPasswords = @(Get-RjPasswordCandidates $archive)
    $archivePasswords = @(Merge-PasswordCandidates $rjPasswords $configuredPasswords)
    if (@($rjPasswords).Count -gt 0) {
        Write-Host "  已从路径/缓存/DLsite 生成 $(@($rjPasswords).Count) 个 RJ 大小写候选"
    }
    $passwordResult = Find-ArchivePassword $archive $archivePasswords
    if (-not $passwordResult.Found) {
        $failureReason = if ($passwordResult.EncryptedPayloadDetected) {
            '目录可读，但加密内容未通过完整校验；密码不匹配或数据损坏'
        } else {
            '无法读取、密码不匹配、缺卷或文件损坏'
        }
        Write-Host "  失败：$failureReason" -ForegroundColor Red
        $failureCount++
        Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='failed_test'; signature=$signature; reason=$failureReason })
        continue
    }

    $safety = Get-ArchiveSafety $archive $passwordResult.Password $maxBytes $maxFiles
    if (-not $safety.Safe) {
        Write-Host "  拒绝：$($safety.Reason)" -ForegroundColor Red
        $failureCount++
        Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='rejected'; reason=$safety.Reason })
        continue
    }

    $listingRjPasswords = @(Get-RjPasswordCandidatesFromListing $archive)
    if (@($listingRjPasswords).Count -gt 0) {
        $archivePasswords = @(Merge-PasswordCandidates (@($rjPasswords) + $listingRjPasswords) $configuredPasswords)
        $newListingCandidates = @($listingRjPasswords | Where-Object { $_ -notin $rjPasswords })
        if (@($newListingCandidates).Count -gt 0) {
            Write-Host "  已从压缩包可见目录补充 $(@($newListingCandidates).Count) 个 RJ 大小写密码候选" -ForegroundColor DarkGray
        }
    }

    $planCount++
    Write-Host "  可解压：$($safety.Files) 项，预计 $([Math]::Round($safety.Bytes / 1MB, 2)) MB" -ForegroundColor Green
    if (-not $Run) {
        Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='planned'; files=$safety.Files; bytes=$safety.Bytes; password_index=$passwordResult.PasswordIndex })
        continue
    }

    # 第一层遵循用户选择；内层压缩包始终在其所在目录旁展开，保留层级关系。
    $currentOutputRoot = if ($ExtractToSource -or $job.Depth -gt 0) {
        Split-Path -LiteralPath $archive
    } else { $OutputRoot }
    New-Item -ItemType Directory -Path $currentOutputRoot -Force | Out-Null
    $baseName = Get-ArchiveBaseName ([IO.Path]::GetFileName($archive))
    $destination = Join-Path $currentOutputRoot $baseName
    if ($destination.Equals($archive,[StringComparison]::OrdinalIgnoreCase)) {
        $destination = if ($job.FinalDirectory -and -not $job.FinalDirectory.Equals($archive,[StringComparison]::OrdinalIgnoreCase)) { $job.FinalDirectory } else { $destination + '_extracted' }
    }
    [void]$packagingRoots.Add($destination)
    $inPlaceMarkerName = ".extract_complete_{0}.json" -f ($baseName -replace '[^A-Za-z0-9_-]', '_')
    $inPlaceMarker = Join-Path $currentOutputRoot $inPlaceMarkerName

    # 就地解压的完成标记位于压缩包父目录，而不是同名内容目录中。
    # 续跑时必须优先识别它，否则压缩包自带的同名顶层目录会被误判为未完成冲突。
    $inPlaceIsFinal=$job.FinalDirectory -and $currentOutputRoot.Equals($job.FinalDirectory,[StringComparison]::OrdinalIgnoreCase)
    if ($job.Depth -gt 0 -and $inPlaceIsFinal -and (Test-ArchiveSourceMarker $inPlaceMarker $archive)) {
        Write-Host "  跳过：已找到就地解压完成标记，不重复解压" -ForegroundColor DarkGray
        Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='skipped_in_place_complete'; output=$currentOutputRoot })

        [object[]]$completedNestedCandidates = @(
            Get-ChildItem -LiteralPath $currentOutputRoot -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -ne $archive -and
                    $_.Name -notlike '.extract_complete*.json' -and
                    (Test-IsArchiveCandidate $_)
                }
        )
        if ($Run -and @($completedNestedCandidates).Count -gt 0) {
            $completedNestedCandidates = @($completedNestedCandidates | ForEach-Object { Repair-ArchiveExtension $_ })
        }
        $completedNestedCandidates = @(Remove-CoveredArchiveCandidates $completedNestedCandidates)
        if ($job.Depth -lt $maxDepth) {
            foreach ($completedNested in $completedNestedCandidates) {
                $queue.Enqueue((New-NestedArchiveJob $completedNested $job $job.TopOutput))
            }
        }
        if (@($completedNestedCandidates).Count -eq 0 -and $job.FinalDirectory) {
            $outputIsFinal = ([IO.Path]::GetFullPath($currentOutputRoot).TrimEnd('\')).Equals(
                [IO.Path]::GetFullPath($job.FinalDirectory).TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase)
            if (-not $outputIsFinal) {
                $commit=Commit-FinalRjDirectory $currentOutputRoot $job.FinalDirectory $archive $true
                if (-not $commit.Success) {
                    $failureCount++
                    Write-Result ([PSCustomObject]@{time=(Get-Date).ToString('o');archive=$archive;status='final_commit_failed';reason=$commit.Reason})
                    continue
                }
                [void]$packagingRoots.Add($currentOutputRoot)
            }
            if (-not $finalDirectories.Contains($job.FinalDirectory)) { $finalDirectories.Add($job.FinalDirectory) }
            Write-Host "  最终作品目录已登记：$($job.FinalDirectory)" -ForegroundColor DarkGray
        }
        continue
    }

    # A disguised inner archive can have an unrecognized extension (for example
    # RJ12345678.pdf). In that case the derived destination is the archive file
    # itself; it is not an existing output directory.
    $destinationIsArchive = ([IO.Path]::GetFullPath($destination)).Equals(
        [IO.Path]::GetFullPath($archive), [StringComparison]::OrdinalIgnoreCase)
    if ((Test-Path -LiteralPath $destination) -and -not $destinationIsArchive) {
        $marker = Join-Path $destination '.extract_complete.json'
        $validMarker=Test-ArchiveSourceMarker $marker $archive
        if ($validMarker -and -not $destination.Equals($job.FinalDirectory,[StringComparison]::OrdinalIgnoreCase)) {
            # A wrapper's extraction marker cannot prove that its moved payload still exists.
            $pending=@(Get-ChildItem -LiteralPath $destination -File -Recurse -Force | Where-Object { Test-IsArchiveCandidate $_ })
            if ($pending.Count -eq 0) { $validMarker=$false }
        }
        if ($validMarker) {
            Write-Host "  跳过：目标带有完成标记，不重复解压" -ForegroundColor DarkGray
            Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='skipped_complete'; output=$destination })
            $skippedNestedCandidates = @(
                Get-ChildItem -LiteralPath $destination -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { Test-IsArchiveCandidate $_ }
            )
            if ($Run -and @($skippedNestedCandidates).Count -gt 0) {
                $skippedNestedCandidates = @($skippedNestedCandidates | ForEach-Object { Repair-ArchiveExtension $_ })
            }
            $skippedNestedCandidates = @(Remove-CoveredArchiveCandidates $skippedNestedCandidates)
            if ($job.Depth -lt $maxDepth) {
                $skippedNestedCandidates | ForEach-Object {
                    $queue.Enqueue((New-NestedArchiveJob $_ $job $destination))
                }
            }
            if (@($skippedNestedCandidates).Count -eq 0 -and $job.FinalDirectory -and
                ([IO.Path]::GetFullPath($destination).TrimEnd('\')).Equals(
                    [IO.Path]::GetFullPath($job.FinalDirectory).TrimEnd('\'),
                    [StringComparison]::OrdinalIgnoreCase)) {
                if (-not $finalDirectories.Contains($job.FinalDirectory)) { $finalDirectories.Add($job.FinalDirectory) }
                Write-Host "  最终作品目录已登记：$($job.FinalDirectory)" -ForegroundColor DarkGray
            }
            continue
        }
        # Do not trust old/foreign completion markers. Extract separately and compare content.
        $destination = "$destination.__incoming__$([guid]::NewGuid().ToString('N').Substring(0,8))"
        [void]$packagingRoots.Add($destination)
    }
    $temporary = "$destination.__extracting__"
    if (Test-Path -LiteralPath $temporary) {
        Write-Result ([PSCustomObject]@{status='preserved_failed_output';path=$temporary;reason='旧解压现场保留，本次使用独立暂存目录'})
        $destination += ".__incoming__$([guid]::NewGuid().ToString('N').Substring(0,8))"
        [void]$packagingRoots.Add($destination)
        $temporary="$destination.__extracting__"
    }
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null

    # Find-ArchivePassword already verifies encrypted payloads. Once it selects a
    # password, changing passwords cannot repair a later data or filesystem error.
    # Extract once and retain the failure scene instead of rewriting it per candidate.
    $attemptPassword = $passwordResult.Password
    $passwordArgument = if ($null -eq $attemptPassword) { "-p-" } else { "-p$attemptPassword" }
    $extractArguments = @("x", "-bd", "-y", $passwordArgument, "-o$temporary") + @(Get-ArchiveNameCodePageArguments $archive) + @("--", $archive)
    Write-Host "  开始解压：$archive；引擎：$script:extractionEngine；密码检查已完成"
    Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='extraction_started'; engine=$script:extractionEngine })
    if ($script:extractionEngine -eq 'bandizip') {
        $extract = Invoke-BandizipExtraction -Executable $script:bandizip -Archive $archive -Destination $temporary -Password $attemptPassword -CodePage (Get-SelectedArchiveCodePage $archive)
    } else { $extract = Invoke-7ZipCapture $extractArguments }
    $extractSucceeded = $extract.ExitCode -eq 0
    $successfulPasswordIndex = $passwordResult.PasswordIndex
    if (-not $extractSucceeded) {
        $engineOutput = $extract.Output -join "`n"
        $failureReason = if ($engineOutput -match '(?i)CRC|data error|corrupt|damaged|invalid (distance|literal|length)|数据错误|损坏') {
            "解压内容校验失败，不再更换密码重试（$script:extractionEngine 退出代码 $($extract.ExitCode)）"
        } else {
            "解压失败，不再更换密码重试（$script:extractionEngine 退出代码 $($extract.ExitCode)）"
        }
        Write-Host "  $failureReason；现场保留：$temporary" -ForegroundColor Red
        $failureCount++
        Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='failed_extract'; reason=$failureReason; engine_exit_code=$extract.ExitCode; failure_directory=$temporary })
        continue
    }

    [object[]]$temporaryNestedCandidates = @(
        Get-ChildItem -LiteralPath $temporary -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { Test-IsArchiveCandidate $_ }
    )
    if ($Run -and @($temporaryNestedCandidates).Count -gt 0) {
        $temporaryNestedCandidates = @($temporaryNestedCandidates | ForEach-Object { Repair-ArchiveExtension $_ })
        $temporaryNestedCandidates = @(Remove-CoveredArchiveCandidates $temporaryNestedCandidates)
    }
    [object[]]$siblingArchiveCandidates = @(
        Get-ChildItem -LiteralPath (Split-Path -LiteralPath $archive) -File -ErrorAction SilentlyContinue |
            Where-Object { Test-IsArchiveCandidate $_ }
    )
    $siblingArchiveCandidates = @(Remove-CoveredArchiveCandidates $siblingArchiveCandidates)
    $currentOutputRjCode = Get-RjCode $currentOutputRoot
    $extractInPlace = (
        $job.Depth -gt 0 -and
        $archiveConfig.nested_final_extract_in_place -and
        $job.RjCode -and
        $currentOutputRjCode -and
        $job.RjCode.Equals($currentOutputRjCode, [StringComparison]::OrdinalIgnoreCase) -and
        @($temporaryNestedCandidates).Count -eq 0 -and
        @($siblingArchiveCandidates).Count -le 1
    )

    $sourceSize = (Get-Item -LiteralPath $archive).Length
    if ($extractInPlace) {
        $merge=Merge-ExtractionPayload $temporary $currentOutputRoot $archive $false
        if (-not $merge.Success) {
            $failureCount++
            Write-Host "内容冲突，解压现场保留：$($merge.Reason)" -ForegroundColor Red
            Write-Result ([PSCustomObject]@{time=(Get-Date).ToString('o');archive=$archive;status='merge_conflict';temporary=$temporary;reason=$merge.Reason})
            continue
        }
        Remove-CompletedPackagingTrees -Roots @($temporary) -FinalDirectories @() | ForEach-Object { Write-Result $_ }
        $destination = $currentOutputRoot
        $markerName = ".extract_complete_{0}.json" -f ((Get-ArchiveBaseName ([IO.Path]::GetFileName($archive))) -replace '[^A-Za-z0-9_-]', '_')
        $markerPath = Join-Path $destination $markerName
        [PSCustomObject]@{
            completed = (Get-Date).ToString('o')
            source_name = [IO.Path]::GetFileName($archive)
            source_size = $sourceSize
            source_modified_ticks = [string](Get-Item -LiteralPath $archive).LastWriteTimeUtc.Ticks
            extracted_in_place = $true
        } | ConvertTo-Json | Out-File -LiteralPath $markerPath -Encoding utf8
        Write-Host "  最终内容已直接解到：$destination" -ForegroundColor Green
    }
    else {
        Move-Item -LiteralPath $temporary -Destination $destination -ErrorAction Stop
        [PSCustomObject]@{
            completed = (Get-Date).ToString('o')
            source_name = [IO.Path]::GetFileName($archive)
            source_size = $sourceSize
            source_modified_ticks = [string](Get-Item -LiteralPath $archive).LastWriteTimeUtc.Ticks
            extracted_in_place = $false
        } | ConvertTo-Json | Out-File -LiteralPath (Join-Path $destination '.extract_complete.json') -Encoding utf8
        Write-Host "  完成：$destination" -ForegroundColor Green
    }
    $topOutput = if ($job.Depth -eq 0) { $destination } else { $job.TopOutput }
    if ($job.Depth -eq 0 -and [IO.Path]::GetFileName($destination) -match '^[0-9]{7,8}(?:\s*\([0-9]+\))?$') {
        $completedNumericWrappers.Add([PSCustomObject]@{ Wrapper=$destination; SourceArchive=$archive })
    }
    $successCount++
    Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='extracted'; output=$destination; password_index=$successfulPasswordIndex })

    [object[]]$nestedCandidates = @(if (-not $extractInPlace) {
        Get-ChildItem -LiteralPath $destination -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { Test-IsArchiveCandidate $_ }
    })
    if (@($nestedCandidates).Count -gt 0) {
        $nestedCandidates = @(Remove-CoveredArchiveCandidates $nestedCandidates)
    }
    if (@($nestedCandidates).Count -gt 0) {
        if ($job.Depth -ge $maxDepth) {
            $remainingNestedCount += @($nestedCandidates).Count
            $failureCount++
            Write-Host "  警告：达到最大递归层数，仍有 $(@($nestedCandidates).Count) 个内层压缩包" -ForegroundColor Red
            Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; depth=$job.Depth; status='depth_limit'; remaining=@($nestedCandidates).Count })
        }
        else {
            foreach ($nested in $nestedCandidates) {
                $queue.Enqueue((New-NestedArchiveJob $nested $job $topOutput))
            }
        }
    }
    elseif (-not $extractInPlace -and $archiveConfig.final_folder_mode -eq 'rj' -and $job.FinalDirectory) {
        $destinationIsFinal = ([IO.Path]::GetFullPath($destination).TrimEnd('\')).Equals(
            [IO.Path]::GetFullPath($job.FinalDirectory).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase)
        if ($destinationIsFinal) {
            if (-not $finalDirectories.Contains($job.FinalDirectory)) { $finalDirectories.Add($job.FinalDirectory) }
            Write-Host "  单层作品已登记：$($job.FinalDirectory)" -ForegroundColor Green
        }
        else {
            $allowExistingFinal = $job.Depth -gt 0 -and $job.TopOutput -and
                ([IO.Path]::GetFullPath($job.TopOutput).TrimEnd('\')).Equals(
                    [IO.Path]::GetFullPath($job.FinalDirectory).TrimEnd('\'),
                    [StringComparison]::OrdinalIgnoreCase)
            $commit = Commit-FinalRjDirectory $destination $job.FinalDirectory $archive $allowExistingFinal
            if (-not $commit.Success) {
                Write-Host "  单层作品提交失败：$($commit.Reason)" -ForegroundColor Red
                $failureCount++
                Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; status='single_layer_commit_failed'; reason=$commit.Reason })
                continue
            }
            if (Test-Path -LiteralPath $destination -PathType Container) {
                [void]$packagingRoots.Add($destination)
            }
            if (-not $finalDirectories.Contains($job.FinalDirectory)) { $finalDirectories.Add($job.FinalDirectory) }
            Write-Host "  单层作品已整理为：$($job.FinalDirectory)" -ForegroundColor Green
        }
    }

    if ($extractInPlace -and $archiveConfig.final_folder_mode -eq 'rj' -and $job.FinalDirectory) {
        $allowExistingFinal = $job.Depth -gt 0 -and $job.TopOutput -and
            ([IO.Path]::GetFullPath($job.TopOutput).TrimEnd('\')).Equals(
                [IO.Path]::GetFullPath($job.FinalDirectory).TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase)
        $commit = Commit-FinalRjDirectory $destination $job.FinalDirectory $archive $allowExistingFinal
        if (-not $commit.Success) {
            Write-Host "  最终目录提交失败：$($commit.Reason)" -ForegroundColor Red
            $failureCount++
            Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); archive=$archive; status='final_commit_failed'; reason=$commit.Reason })
            continue
        }
        Write-Host "  最终作品目录：$($job.FinalDirectory)" -ForegroundColor Green
        if (-not $finalDirectories.Contains($job.FinalDirectory)) { $finalDirectories.Add($job.FinalDirectory) }
    }

    # All source/intermediate archive removal is deferred until every queued child commits.
    } finally {
        if ($lockHeld) { $workLock.ReleaseMutex() }
        $workLock.Dispose()
    }
}

# Hold the same work locks during final cleanup, so another project's commit
# cannot race with wrapper folding or source removal. Acquire in stable order.
$cleanupLocks=[Collections.Generic.List[Threading.Mutex]]::new()
try {
    if ($Run -and $failureCount -eq 0) {
        foreach ($directory in @($finalDirectories | Sort-Object -Unique)) {
            $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($directory.ToLowerInvariant())))
            $mutex=[Threading.Mutex]::new($false,"Local\ArchiveWork_$key")
            $held=$false
            try { $held=$mutex.WaitOne(120000) } catch [Threading.AbandonedMutexException] { $held=$true }
            if (-not $held) { $mutex.Dispose(); throw "等待作品收尾超时：$directory" }
            $cleanupLocks.Add($mutex)
        }
    }

if ($Run -and $failureCount -eq 0) {
    foreach ($cleanup in @(Repair-CompletedArchiveCleanup -Roots @($finalDirectories) -DeleteParts ($archiveConfig.intermediate_archive_action -eq 'delete'))) {
        Write-Host "完成后清理：$($cleanup.path)" -ForegroundColor DarkGray
        Write-Result $cleanup
    }
}

if ($Run -and $failureCount -eq 0 -and $archiveConfig.collapse_packaging_directories) {
    $pathWarningLength = if ($archiveConfig.PSObject.Properties['packaging_path_warning_length']) {
        [int]$archiveConfig.packaging_path_warning_length
    } else { 240 }
    foreach ($collapse in @(Collapse-PackagingDirectories -Roots @($finalDirectories) -PathWarningLength $pathWarningLength)) {
        Write-Host "折叠包装目录：$($collapse.path) -> $($collapse.destination) [$($collapse.reason)]" -ForegroundColor DarkGray
        Write-Result $collapse
    }
}




if ($Run -and $failureCount -eq 0) {
    try {
        foreach ($directory in $finalDirectories) {
            [void](Assert-ExtractionTree $directory)
            if (@(Get-ChildItem -LiteralPath $directory -File -Recurse -Force | Where-Object { $_.Name -notlike '.extract_complete*.json' }).Count -eq 0) {
                throw "最终目录没有作品内容，保留全部原包：$directory"
            }
        }
        if ($finalDirectories.Count -eq 0) { throw '没有成功提交的作品目录，保留全部原包' }
        # Verify every candidate before deleting the first one. A changed input aborts cleanup.
        foreach ($candidate in $archiveDeletionCandidates.Values) {
            if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
            $info=Get-Item -LiteralPath $candidate.Path -Force
            if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint -or $info.Length -ne $candidate.Size -or
                $info.LastWriteTimeUtc.Ticks -ne $candidate.Modified) { throw "压缩包在任务期间发生变化，保留：$($candidate.Path)" }
        }
        # Remove nested originals first; package attachment quarantine needs the outer source receipt.
        $numericCleaned=$false
        foreach ($candidate in @($archiveDeletionCandidates.Values | Sort-Object Depth -Descending)) {
            if ($candidate.Depth -eq 0 -and -not $numericCleaned) {
                $numericCleaned=$true
                Remove-CompletedPackagingTrees -Roots @(@($packagingRoots) + @($finalDirectories)) -FinalDirectories @($finalDirectories) |
                    ForEach-Object { Write-Result $_ }
                if ($archiveConfig.collapse_packaging_directories) {
                    $packagingQuarantine = Join-Path $PSScriptRoot ('quarantine\packaging_directories\' + (Get-Date -Format 'yyyyMMdd'))
                    foreach ($wrapper in $completedNumericWrappers) {
                        foreach ($cleanup in @(Move-CompletedNumericPackagingResidue -Wrapper $wrapper.Wrapper -SourceArchive $wrapper.SourceArchive -FinalDirectories @($finalDirectories) -QuarantineRoot $packagingQuarantine)) {
                            Write-Host "包装附件已保留到隔离区：$($cleanup.path) -> $($cleanup.destination)" -ForegroundColor DarkGray
                            Write-Result $cleanup
                        }
                    }
                }
            }
            $delete=if ($candidate.Depth -eq 0) { -not $archiveConfig.keep_original_archives } else {
                $archiveConfig.intermediate_archive_action -eq 'delete' -or $archiveConfig.nested_final_archive_action -eq 'delete'
            }
            if ($delete -and (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) {
                Remove-Item -LiteralPath $candidate.Path -Force -ErrorAction Stop
                $deletedSourceArchives.Add($candidate.Path)
                Write-Result ([PSCustomObject]@{status='deleted_completed_archive';archive=$candidate.Path;size=$candidate.Size})
                Write-Host "已删除完成的压缩包：$($candidate.Path)" -ForegroundColor DarkGray
            }
        }
        Remove-CompletedPackagingTrees -Roots @(@($packagingRoots) + @($finalDirectories)) -FinalDirectories @($finalDirectories) |
            ForEach-Object { Write-Result $_; if ($_.status -eq 'deleted_completed_packaging') { Write-Host "已清理包装目录：$($_.path)" -ForegroundColor DarkGray } }
        foreach ($directory in $packagingRoots) {
            if ((Test-Path -LiteralPath $directory -PathType Container) -and -not $finalDirectories.Contains($directory)) {
                $preservedPackaging.Add($directory)
                Write-Result ([PSCustomObject]@{status='preserved_packaging';path=$directory;reason='仍含附件、保留的压缩包或其他内容'})
            }
        }
    } catch {
        $failureCount++
        Write-Host "收尾未完成，剩余文件保留：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Result ([PSCustomObject]@{status='cleanup_failed';archive=($resolvedInputs -join ', ');reason=$_.Exception.Message})
    }
}

} catch {
    $failureCount++
    Write-Host "收尾失败，剩余文件保留：$($_.Exception.Message)" -ForegroundColor Yellow
    Write-Result ([PSCustomObject]@{status='cleanup_failed';archive=($resolvedInputs -join ', ');reason=$_.Exception.Message})
} finally {
    foreach ($mutex in $cleanupLocks) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

$failureStatusText = @{
    cleanup_failed = '解压收尾失败'
    rejected_plain_pe = '不是可解压的自解压包'
    failed_test = '密码不匹配、缺卷、文件损坏或无法读取'
    rejected = '安全检查拒绝'
    output_conflict = '目标目录已存在且没有完成标记'
    failed_extract = '解压失败'
    merge_conflict = '解压内容与已有文件同名冲突'
    depth_limit = '达到最大递归层数'
    single_layer_commit_failed = '最终目录提交失败'
    final_commit_failed = '最终目录提交失败'
}
$failedArchives = @(
    if (Test-Path -LiteralPath $script:logPath -PathType Leaf) {
        Get-Content -LiteralPath $script:logPath -Encoding utf8 | ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { $null }
        } | Where-Object { $_ -and $failureStatusText.ContainsKey([string]$_.status) -and $_.archive } |
            ForEach-Object {
                [PSCustomObject]@{
                    archive = [string]$_.archive
                    status = [string]$_.status
                    reason = $(if ($_.PSObject.Properties['reason'] -and $_.reason) { [string]$_.reason } else { $failureStatusText[[string]$_.status] })
                }
            } | Sort-Object archive, status -Unique
    }
)

Write-Host ""
Write-Host "==============================" -ForegroundColor Cyan
Write-Host "可处理：$planCount"
Write-Host "成功解压：$successCount" -ForegroundColor Green
Write-Host "失败或拒绝：$failureCount" -ForegroundColor $(if ($failureCount) { 'Red' } else { 'Green' })
Write-Host "实际递归深度：$maxObservedDepth"
Write-Host "达到上限后残留内层包：$remainingNestedCount" -ForegroundColor $(if ($remainingNestedCount) { 'Red' } else { 'Green' })
Write-Host "日志：$script:logPath"
Write-Host "已删除完成的压缩包：$($deletedSourceArchives.Count) 个"
Write-Host "原包策略：$(if ($archiveConfig.keep_original_archives) { '保留外层原包' } else { '整组成功后删除；失败组保留' })"
foreach ($residue in $preservedPackaging) { Write-Host "保留包装目录（仍有内容）：$residue" -ForegroundColor Yellow }
if ($failedArchives.Count -gt 0) {
    Write-Host '失败压缩包：' -ForegroundColor Red
    foreach ($failedArchive in $failedArchives) {
        Write-Host "  $($failedArchive.archive)" -ForegroundColor Red
        Write-Host "    原因：$($failedArchive.reason)" -ForegroundColor Yellow
    }
}
Write-Host "=============================="

if ($ResultFile) {
    $resultParent = Split-Path -LiteralPath $ResultFile
    if ($resultParent) { New-Item -ItemType Directory -Path $resultParent -Force | Out-Null }
    [PSCustomObject]@{
        completed = (Get-Date).ToString('o')
        success = ($failureCount -eq 0)
        failure_count = $failureCount
        final_directories = @($finalDirectories)
        source_archives = @($sourceArchiveSnapshots)
        failed_archives = @($failedArchives)
        deleted_archives = @($deletedSourceArchives)
        preserved_packaging = @($preservedPackaging)
    } | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $ResultFile -Encoding utf8
}

if ($failureCount -gt 0) { exit 2 }
exit 0
