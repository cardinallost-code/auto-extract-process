#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath,
    [switch]$Run,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'src\lossless-audio.ps1')
$script:audioDecodeCache = @{}

function Stop-WithError([string]$Message, [int]$Code = 1) {
    Write-Host "[错误] $Message" -ForegroundColor Red
    exit $Code
}

function Find-Executable([string]$Name, [string[]]$Fallbacks) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($path in $Fallbacks) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    return $null
}

function Get-AudioInfo([string]$Path) {
    if ($script:audioInfoCache.ContainsKey($Path)) { return $script:audioInfoCache[$Path] }
    $output = & $script:ffprobe -v error -select_streams a:0 `
        -show_entries 'stream=codec_name,bit_rate:format=duration,bit_rate' -of json -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { $script:audioInfoCache[$Path]=$null; return $null }
    try {
        $data = $output | ConvertFrom-Json -ErrorAction Stop
        $stream = @($data.streams)[0]
        if (-not $stream) { return $null }
        $duration = 0.0
        if (-not [double]::TryParse([string]$data.format.duration,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$duration)) { return $null }
        $bitrate = 0L
        $bitrateText = if ($stream.PSObject.Properties['bit_rate'] -and $stream.bit_rate) { $stream.bit_rate }
            elseif ($data.format.PSObject.Properties['bit_rate']) { $data.format.bit_rate } else { '0' }
        [void][long]::TryParse([string]$bitrateText, [ref]$bitrate)
        $info = [PSCustomObject]@{ Codec=[string]$stream.codec_name; Duration=$duration; Bitrate=$bitrate }
        $script:audioInfoCache[$Path] = $info
        return $info
    }
    catch { $script:audioInfoCache[$Path]=$null; return $null }
}

function Get-NormalizedTrackName([string]$Name) {
    $value = $Name.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
    $value = $value -replace '[\s_＿-]+', ''
    return $value
}

function Get-CoreTrackName([string]$Name) {
    $value = $Name.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
    $value = $value -replace '(効果音|se|sfx|bgm)\s*(あり|有り|有|なし|無し|無|入り|付き|抜き|on|off)', ''
    $value = $value -replace '(with|without|no)\s*(se|sfx|bgm)', ''
    $value = $value -replace '(音声のみ|wav|wave|mp3|flac|24bit|16bit|hires|ハイレゾ)', ''
    $value = $value -replace '[\s_＿\-\.\[\]【】\(\)]+', ''
    return $value
}

function Get-TrackNumberKey([string]$Name) {
    $value = $Name.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
    if ($value -match '^\s*(?:(?:track|trk|トラック)\s*)?0*(\d{1,3})(?:\s*[-_.－―]\s*0*(\d{1,3}))?') {
        $first = [int]$Matches[1]
        $second = if ($Matches[2]) { [int]$Matches[2] } else { $null }
        if ($null -ne $second) { return "$first.$second" }
        return "$first"
    }
    return $null
}

function Get-PathProfile([IO.FileInfo]$File, [string]$Root) {
    $relativeDirectory = [IO.Path]::GetRelativePath($Root, $File.DirectoryName)
    $rawSegments = @($relativeDirectory -split '[\\/]+' | Where-Object { $_ -and $_ -ne '.' })
    $segments = [Collections.Generic.List[string]]::new()
    foreach ($segment in $rawSegments) {
        $normalized = $segment.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
        $normalized = $normalized -replace '[\s_＿\-\.\[\]【】\(\)]+', ''
        if ($normalized -and $normalized -notin @('wav','wave','flac','mp3','audio','音声')) {
            $segments.Add($normalized)
        }
    }
    $joined = $segments -join '/'

    $effects = 'unknown'
    if ($joined -match '(効果音|se|sfx)(なし|無し|無|抜き|off)|(^|/)no(se|sfx)($|/)|without(se|sfx)|音声のみ') {
        $effects = 'without'
    }
    elseif ($joined -match '(効果音|se|sfx)(あり|有り|有|入り|付き|on)|with(se|sfx)|(^|/)(se|sfx)($|/)') {
        $effects = 'with'
    }

    $bgm = 'unknown'
    if ($joined -match 'bgm(なし|無し|無|抜き|off)|(^|/)nobgm($|/)|withoutbgm') { $bgm = 'without' }
    elseif ($joined -match 'bgm(あり|有り|有|入り|付き|on)|withbgm|(^|/)bgm($|/)') { $bgm = 'with' }

    return [PSCustomObject]@{
        Segments = @($segments)
        Signature = $joined
        Effects = $effects
        Bgm = $bgm
    }
}

function Get-PathMatchScore($WavProfile, $Mp3Profile, [bool]$SameDirectory) {
    if ($WavProfile.Effects -ne 'unknown' -and $Mp3Profile.Effects -ne 'unknown' -and
        $WavProfile.Effects -ne $Mp3Profile.Effects) { return -100000 }
    if ($WavProfile.Bgm -ne 'unknown' -and $Mp3Profile.Bgm -ne 'unknown' -and
        $WavProfile.Bgm -ne $Mp3Profile.Bgm) { return -100000 }

    $score = if ($SameDirectory) { 300 } else { 0 }
    # 普通本篇不应与明确标注为 SE/BGM 变体的 MP3 同等竞争。
    if ($WavProfile.Effects -eq 'unknown' -and $Mp3Profile.Effects -ne 'unknown') { $score -= 240 }
    if ($WavProfile.Bgm -eq 'unknown' -and $Mp3Profile.Bgm -ne 'unknown') { $score -= 160 }
    if ($WavProfile.Signature -and $WavProfile.Signature -eq $Mp3Profile.Signature) { $score += 200 }
    if ($WavProfile.Effects -ne 'unknown' -and $WavProfile.Effects -eq $Mp3Profile.Effects) { $score += 120 }
    if ($WavProfile.Bgm -ne 'unknown' -and $WavProfile.Bgm -eq $Mp3Profile.Bgm) { $score += 80 }

    $wavSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($segment in $WavProfile.Segments) { [void]$wavSet.Add($segment) }
    foreach ($segment in $Mp3Profile.Segments) {
        if ($wavSet.Contains($segment)) { $score += 15 }
    }

    $wavSegments = @($WavProfile.Segments)
    $mp3Segments = @($Mp3Profile.Segments)
    $suffixCount = [Math]::Min($wavSegments.Count, $mp3Segments.Count)
    for ($index = 1; $index -le $suffixCount; $index++) {
        if ($wavSegments[-$index] -eq $mp3Segments[-$index]) { $score += 20 } else { break }
    }
    return $score
}

function Test-MatchingAudio([string]$WavPath, [string]$Mp3Path) {
    $wavInfo = Get-AudioInfo $WavPath
    $mp3Info = Get-AudioInfo $Mp3Path
    if (-not $wavInfo -or -not $mp3Info -or $mp3Info.Codec -ne 'mp3') { return $false }
    $tolerance = [Math]::Max(1.0, $wavInfo.Duration * 0.01)
    if ([Math]::Abs($wavInfo.Duration - $mp3Info.Duration) -gt $tolerance) { return $false }
    if ([IO.Path]::GetExtension($WavPath) -ieq '.flac') {
        return $wavInfo.Codec -eq 'flac' -and (Test-AudioDecode $WavPath) -and (Test-AudioDecode $Mp3Path)
    }
    return $true
}

function Find-NativeMp3([IO.FileInfo]$Wav, [IO.FileInfo[]]$AllMp3, [string]$Root) {
    $key = Get-NormalizedTrackName $Wav.BaseName
    $coreKey = Get-CoreTrackName $Wav.BaseName
    $numberKey = Get-TrackNumberKey $Wav.BaseName
    $wavProfile = Get-PathProfile $Wav $Root
    $wavContext = Get-VersionContext $Wav.DirectoryName $Root
    $wavInfo = Get-AudioInfo $Wav.FullName
    if (-not $wavInfo) { return $null }
    $ranked = @(@(
        foreach ($candidate in $AllMp3) {
            $candidateKey = Get-NormalizedTrackName $candidate.BaseName
            $candidateCore = Get-CoreTrackName $candidate.BaseName
            $candidateNumber = Get-TrackNumberKey $candidate.BaseName
            if ($numberKey -and $candidateNumber -and $numberKey -ne $candidateNumber) { continue }

            $mp3Info = Get-AudioInfo $candidate.FullName
            if (-not $mp3Info -or $mp3Info.Codec -ne 'mp3') { continue }
            $tolerance = [Math]::Max(1.0, $wavInfo.Duration * 0.01)
            $durationDifference = [Math]::Abs($wavInfo.Duration - $mp3Info.Duration)
            if ($durationDifference -gt $tolerance) { continue }

            $mp3Profile = Get-PathProfile $candidate $Root
            $score = Get-PathMatchScore $wavProfile $mp3Profile ($candidate.DirectoryName -eq $Wav.DirectoryName)
            if ($score -le -100000) { continue }
            $candidateContext = Get-VersionContext $candidate.DirectoryName $Root
            if ($candidateContext -eq $wavContext) { $score += 360 }
            $candidateRelativeDirectory = [IO.Path]::GetRelativePath($Root, $candidate.DirectoryName)
            if ($candidateRelativeDirectory -match '(?i)(mp3\s*軽量版|軽量版)') { $score += 100 }
            if ($candidateKey -eq $key) { $score += 500 }
            elseif ($coreKey -and $candidateCore -eq $coreKey) { $score += 300 }
            if ($numberKey -and $candidateNumber -eq $numberKey) { $score += 220 }
            if ($durationDifference -le 0.1) { $score += 140 }
            elseif ($durationDifference -le 0.5) { $score += 100 }
            else { $score += 60 }
            [PSCustomObject]@{ File=$candidate; Score=$score; DurationDifference=$durationDifference }
        }
    ) | Sort-Object Score -Descending)

    if ($ranked.Count -eq 0 -or $ranked[0].Score -lt 220) { return $null }
    if ($ranked.Count -gt 1 -and ($ranked[0].Score - $ranked[1].Score) -lt 60) { return $null }
    return $ranked[0].File
}

function Get-VersionContext([string]$Directory, [string]$Root) {
    $relative = [IO.Path]::GetRelativePath($Root, $Directory)
    $parts = foreach ($part in @($relative -split '[\\/]+')) {
        $value = $part.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
        $value = $value -replace '^[①-⑳❶-❿⓵-⓾\d]+[\s._　-]*', ''
        $value = $value -replace '(mp3|wav|wave)?\s*軽量版', ''
        $value = $value -replace '(mp3|wav|wave|flac|24bit|16bit|ハイレゾ|本編)', ''
        $value = $value -replace '[\s_＿\-\.\[\]【】\(\)]+', ''
        if ($value) { $value }
    }
    return (@($parts) -join '/')
}

function Get-DirectoryAudioSet([object]$Group) {
    return @(
        foreach ($file in @($Group.Group)) {
            $info = Get-AudioInfo $file.FullName
            if ($info -and $info.Codec -eq 'mp3') {
                [PSCustomObject]@{
                    File = $file
                    Info = $info
                    NameKey = Get-NormalizedTrackName $file.BaseName
                    NumberKey = Get-TrackNumberKey $file.BaseName
                }
            }
        }
    )
}

function Test-CompleteAudioSetMatch([object[]]$NativeSet, [object[]]$ConvertedSet) {
    if ($ConvertedSet.Count -eq 0 -or $NativeSet.Count -lt $ConvertedSet.Count) { return $false }
    $available = [Collections.Generic.List[object]]::new()
    foreach ($item in $NativeSet) { $available.Add($item) }

    # 先处理有轨道号的文件，再用时长做一对一匹配；文件名只用于解决候选并列。
    foreach ($converted in @($ConvertedSet | Sort-Object @{Expression={if ($_.NumberKey) {0} else {1}}}, {$_.File.Name})) {
        $ranked = @(@(
            foreach ($native in $available) {
                $tolerance = [Math]::Max(1.0, $converted.Info.Duration * 0.01)
                $difference = [Math]::Abs($converted.Info.Duration - $native.Info.Duration)
                if ($difference -gt $tolerance) { continue }
                if ($converted.NumberKey -and $native.NumberKey -and $converted.NumberKey -ne $native.NumberKey) { continue }
                $score = -$difference
                if ($converted.NumberKey -and $converted.NumberKey -eq $native.NumberKey) { $score += 1000 }
                if ($converted.NameKey -eq $native.NameKey) { $score += 500 }
                [PSCustomObject]@{ Item=$native; Score=$score }
            }
        ) | Sort-Object Score -Descending)
        if ($ranked.Count -eq 0) { return $false }
        [void]$available.Remove($ranked[0].Item)
    }
    return $true
}

function Get-RedundantConvertedMp3([IO.FileInfo[]]$AllMp3, [string]$Root) {
    $redundant = [Collections.Generic.List[IO.FileInfo]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $groups = @($AllMp3 | Group-Object DirectoryName)
    $nativeGroups = @($groups | Where-Object { $_.Name -match '(?i)(mp3\s*軽量版|軽量版)' })
    $convertedGroups = @($groups | Where-Object { $_.Name -notmatch '(?i)(mp3\s*軽量版|軽量版)' })

    foreach ($nativeGroup in $nativeGroups) {
        $nativeContext = Get-VersionContext $nativeGroup.Name $Root
        $nativeProfile = Get-PathProfile $nativeGroup.Group[0] $Root
        $nativeSet = @(Get-DirectoryAudioSet $nativeGroup)
        foreach ($convertedGroup in $convertedGroups) {
            if ((Get-VersionContext $convertedGroup.Name $Root) -ne $nativeContext) { continue }
            $convertedProfile = Get-PathProfile $convertedGroup.Group[0] $Root
            if ($nativeProfile.Effects -ne $convertedProfile.Effects -or $nativeProfile.Bgm -ne $convertedProfile.Bgm) { continue }
            $convertedSet = @(Get-DirectoryAudioSet $convertedGroup)
            if (-not (Test-CompleteAudioSetMatch $nativeSet $convertedSet)) { continue }
            foreach ($item in $convertedSet) {
                if ($seen.Add($item.File.FullName)) { $redundant.Add($item.File) }
            }
        }
    }
    return @($redundant)
}

function Remove-EmptyParents(
    [string]$StartDirectory,
    [string]$Root,
    [Collections.Generic.HashSet[string]]$ProtectedDirectories = $null
) {
    $current = $StartDirectory
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    while ($current -and [IO.Path]::GetFullPath($current).TrimEnd('\') -ne $rootFull) {
        $currentFull = [IO.Path]::GetFullPath($current).TrimEnd('\')
        if ($ProtectedDirectories -and $ProtectedDirectories.Contains($currentFull)) { break }
        if (-not (Test-Path -LiteralPath $current -PathType Container)) { break }
        if (Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop | Select-Object -First 1) { break }
        $parent = [IO.Directory]::GetParent($current).FullName
        Remove-Item -LiteralPath $current -Force -ErrorAction Stop
        $current = $parent
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Stop-WithError "找不到配置：$ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
$script:audioInfoCache = @{}
$script:ffprobe = Find-Executable 'ffprobe.exe' @('C:\Program Files\ffmpeg\bin\ffprobe.exe')
if (-not $script:ffprobe) { Stop-WithError '未找到 ffprobe.exe' }
$script:ffmpeg = Find-Executable 'ffmpeg.exe' @('C:\Program Files\ffmpeg\bin\ffmpeg.exe')
if (-not $script:ffmpeg) { Stop-WithError '未找到 ffmpeg.exe' }
$audioPlugin = $config.plugins.wav_to_mp3.script
$audioLauncher = $config.plugins.wav_to_mp3.launcher
$deleteEmptyWavDirectories = if ($null -ne $config.processing.PSObject.Properties['delete_empty_wav_directories']) {
    [bool]$config.processing.delete_empty_wav_directories
} else { $true }
$preserveNativeWavDirectories = if ($null -ne $config.processing.PSObject.Properties['preserve_wav_directories_when_work_has_no_mp3']) {
    [bool]$config.processing.preserve_wav_directories_when_work_has_no_mp3
} else { $true }
if (-not (Test-Path -LiteralPath $audioPlugin -PathType Leaf)) { Stop-WithError "找不到 WAV 转 MP3 插件：$audioPlugin" }
if (-not (Test-Path -LiteralPath $audioLauncher -PathType Leaf)) { Stop-WithError "找不到 WAV 转 MP3 BAT：$audioLauncher" }

$roots = [Collections.Generic.List[string]]::new()
foreach ($path in $InputPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Stop-WithError "输入必须是目录：$path" }
    $resolved = (Resolve-Path -LiteralPath $path).Path
    if (-not $roots.Contains($resolved)) { $roots.Add($resolved) }
}

# 把父目录输入拆分为独立作品，禁止不同 RJ作品互相借用 MP3候选。
$workRoots = [Collections.Generic.List[string]]::new()
foreach ($root in $roots) {
    if ((Split-Path -Leaf $root) -match '(?i)^RJ\d{8}(?!\d)') {
        if (-not $workRoots.Contains($root)) { $workRoots.Add($root) }
        continue
    }

    $rjDirectories = @(
        Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object Name -Match '(?i)^RJ\d{8}(?!\d)' |
            Sort-Object { $_.FullName.Length }
    )
    foreach ($directory in $rjDirectories) {
        $coveredByExistingWork = $false
        foreach ($existingWork in $workRoots) {
            if ($directory.FullName.StartsWith($existingWork.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $coveredByExistingWork = $true
                break
            }
        }
        if (-not $coveredByExistingWork -and -not $workRoots.Contains($directory.FullName)) {
            $workRoots.Add($directory.FullName)
        }
    }

    if ($rjDirectories.Count -eq 0) {
        $hasAudio = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object Extension -in '.wav','.flac','.mp3' | Select-Object -First 1
        if ($hasAudio -and -not $workRoots.Contains($root)) { $workRoots.Add($root) }
    }
}
if ($workRoots.Count -eq 0) { Stop-WithError '输入中没有发现 RJ作品目录或音频文件' 2 }

$taskId = Get-Date -Format 'yyyyMMdd_HHmmss'
$logDirectory = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logPath = Join-Path $logDirectory "file_process_$taskId.jsonl"

$nativePairs = [Collections.Generic.List[object]]::new()
$toConvert = [Collections.Generic.List[object]]::new()
$mp4Files = [Collections.Generic.List[IO.FileInfo]]::new()
$redundantMp3 = [Collections.Generic.List[IO.FileInfo]]::new()
$worksWithoutMp3 = 0
$wavFolderDeletionBlocked = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($root in $workRoots) {
    # Protect software/game resources as a whole, even when they contain WAV/MP3/MP4.
    $softwareFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop |
        Where-Object { $_.Extension -match '(?i)^\.(exe|dll|so|dylib|pck|rpa|rpgmvp|rpgmvo|rpgmvm)$' -or
            $_.Name -in @('Game.rgss3a','Game.rgss2a','Game.rgssad','data.unity3d','globalgamemanagers') })
    if ($softwareFiles.Count -gt 0) {
        Write-Host "游戏/软件保护：$root；跳过音频转换及全部文件删除。" -ForegroundColor Yellow
        [PSCustomObject]@{time=(Get-Date).ToString('o');status='skipped_software_work';root=$root;evidence=$softwareFiles[0].FullName} |
            ConvertTo-Json -Compress | Out-File -LiteralPath $logPath -Encoding utf8 -Append
        continue
    }
    # 原本含非 WAV/FLAC 文件的目录，不因无损音频清理而删除。
    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
    foreach ($nonWav in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -notin @('.wav','.flac') })) {
        $current = $nonWav.DirectoryName
        while ($current) {
            $currentFull = [IO.Path]::GetFullPath($current).TrimEnd('\')
            if ($currentFull -eq $rootFull) { break }
            [void]$wavFolderDeletionBlocked.Add($currentFull)
            $current = [IO.Directory]::GetParent($current).FullName
        }
    }
    $wavFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object Extension -in '.wav','.flac')
    $mp3Files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.mp3' -ErrorAction SilentlyContinue)
    foreach ($duplicate in @(Get-RedundantConvertedMp3 $mp3Files $root)) { $redundantMp3.Add($duplicate) }
    foreach ($mp4 in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.mp4' -ErrorAction SilentlyContinue)) {
        $mp4Files.Add($mp4)
    }
    if ($mp3Files.Count -eq 0) {
        $worksWithoutMp3++
        foreach ($wav in $wavFiles) {
            $toConvert.Add([PSCustomObject]@{ Root=$root; Wav=$wav })
            if ($preserveNativeWavDirectories) {
                $current = $wav.DirectoryName
                while ($current) {
                    $currentFull = [IO.Path]::GetFullPath($current).TrimEnd('\')
                    if ($currentFull -eq $rootFull) { break }
                    [void]$wavFolderDeletionBlocked.Add($currentFull)
                    $current = [IO.Directory]::GetParent($current).FullName
                }
            }
        }
        continue
    }
    foreach ($wav in $wavFiles) {
        $native = Find-NativeMp3 $wav $mp3Files $root
        if ($native -and (Test-MatchingAudio $wav.FullName $native.FullName)) {
            $nativePairs.Add([PSCustomObject]@{ Root=$root; Wav=$wav; Mp3=$native })
        }
        else {
            $toConvert.Add([PSCustomObject]@{ Root=$root; Wav=$wav })
        }
    }
}

Write-Host ''
Write-Host "文件处理层：$(if ($Run) { '执行' } else { '安全预演' })" -ForegroundColor Cyan
Write-Host "输入目录：$($roots.Count)"
Write-Host "独立作品：$($workRoots.Count)"
Write-Host "完全没有 MP3、全部转换的作品：$worksWithoutMp3"
Write-Host "检测到 WAV/FLAC：$($nativePairs.Count + $toConvert.Count)"
Write-Host "匹配到有效原生 MP3：$($nativePairs.Count)"
Write-Host "需要转换为 320 kbps：$($toConvert.Count)"
Write-Host "需要删除 MP4：$($mp4Files.Count)"
Write-Host "需要删除的非原生重复 MP3：$($redundantMp3.Count)"
Write-Host "原生 MP3 不要求达到 320 kbps；只校验格式和时长。"

if (-not $Run) {
    Write-Host ''
    foreach ($pair in $nativePairs) { Write-Host "保留原生 MP3，删除 $($pair.Wav.Extension.TrimStart('.').ToUpperInvariant())：$($pair.Wav.FullName)" }
    foreach ($item in $toConvert) { Write-Host "转换 320 kbps：$($item.Wav.FullName)" }
    foreach ($mp4 in $mp4Files) { Write-Host "删除 MP4：$($mp4.FullName)" }
    foreach ($mp3 in $redundantMp3) { Write-Host "保留原生 MP3軽量版，删除后转重复 MP3：$($mp3.FullName)" }
    Write-Host ''
    Write-Host '预演完成，没有修改文件。' -ForegroundColor Yellow
    exit 0
}

$failed = 0
$deleted = 0
$deletedFlac = 0
$deletedMp4 = 0
$deletedRedundantMp3 = 0
$converted = 0

foreach ($mp3 in $redundantMp3) {
    try {
        $parentDirectory = $mp3.DirectoryName
        $owningRoot = @($workRoots | Where-Object {
            $mp3.FullName.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object Length -Descending | Select-Object -First 1)[0]
        Remove-Item -LiteralPath $mp3.FullName -Force -ErrorAction Stop
        if ($owningRoot) { Remove-EmptyParents $parentDirectory $owningRoot }
        $deletedRedundantMp3++
        [PSCustomObject]@{time=(Get-Date).ToString('o');status='converted_duplicate_mp3_deleted';mp3=$mp3.FullName} |
            ConvertTo-Json -Compress | Out-File -LiteralPath $logPath -Encoding utf8 -Append
    }
    catch { Write-Host "重复 MP3 删除失败：$($mp3.FullName)；$($_.Exception.Message)" -ForegroundColor Red; $failed++ }
}

foreach ($mp4 in $mp4Files) {
    try {
        $parentDirectory = $mp4.DirectoryName
        $owningRoot = @($workRoots | Where-Object {
            $mp4.FullName.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object Length -Descending | Select-Object -First 1)[0]
        Remove-Item -LiteralPath $mp4.FullName -Force -ErrorAction Stop
        if ($owningRoot) { Remove-EmptyParents $parentDirectory $owningRoot }
        $deletedMp4++
        [PSCustomObject]@{time=(Get-Date).ToString('o');status='mp4_deleted';mp4=$mp4.FullName} |
            ConvertTo-Json -Compress | Out-File -LiteralPath $logPath -Encoding utf8 -Append
    }
    catch { Write-Host "MP4 删除失败：$($mp4.FullName)；$($_.Exception.Message)" -ForegroundColor Red; $failed++ }
}

foreach ($pair in $nativePairs) {
    try {
        if (-not (Test-Path -LiteralPath $pair.Mp3.FullName -PathType Leaf) -or
            -not (Test-MatchingAudio $pair.Wav.FullName $pair.Mp3.FullName)) {
            throw '对应 MP3 已不存在或校验失败，保留源文件'
        }
        $parentDirectory = $pair.Wav.DirectoryName
        Remove-Item -LiteralPath $pair.Wav.FullName -Force -ErrorAction Stop
        if ($deleteEmptyWavDirectories) {
            Remove-EmptyParents $parentDirectory $pair.Root $wavFolderDeletionBlocked
        }
        $format = $pair.Wav.Extension.TrimStart('.').ToLowerInvariant()
        if ($format -eq 'flac') { $deletedFlac++ } else { $deleted++ }
        $record = @{time=(Get-Date).ToString('o');status="native_mp3_kept_${format}_deleted";mp3=$pair.Mp3.FullName}
        $record[$format] = $pair.Wav.FullName
        [PSCustomObject]$record |
            ConvertTo-Json -Compress | Out-File -LiteralPath $logPath -Encoding utf8 -Append
    }
    catch { Write-Host "无损音频删除失败：$($pair.Wav.FullName)；$($_.Exception.Message)" -ForegroundColor Red; $failed++ }
}

if ($toConvert.Count -gt 0) {
    # 原生 MP3对应的 WAV已经删除；此时把作品目录交给外置 BAT，
    # 它只会扫描并转换仍然存在的 WAV，避免超长文件参数列表。
    $conversionRoots = @($toConvert | Where-Object { $_.Wav.Extension -ieq '.wav' } | ForEach-Object Root | Select-Object -Unique)
    if ($conversionRoots.Count -gt 0) {
        $previousAutoMode = $env:WAV_TO_MP3_AUTO
        $previousNoPause = $env:WAV_TO_MP3_NO_PAUSE
        # 自动补漏和无人值守分别控制：不扫描同级目录，也不等待按键。
        $env:WAV_TO_MP3_AUTO = '0'
        $env:WAV_TO_MP3_NO_PAUSE = '1'
        try { & $audioLauncher @conversionRoots }
        finally {
            if ($null -eq $previousAutoMode) { Remove-Item Env:WAV_TO_MP3_AUTO -ErrorAction SilentlyContinue }
            else { $env:WAV_TO_MP3_AUTO = $previousAutoMode }
            if ($null -eq $previousNoPause) { Remove-Item Env:WAV_TO_MP3_NO_PAUSE -ErrorAction SilentlyContinue }
            else { $env:WAV_TO_MP3_NO_PAUSE = $previousNoPause }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WAV 转 MP3 插件返回错误：$LASTEXITCODE" -ForegroundColor Red
            $failed++
        }
    }

    foreach ($item in $toConvert) {
        $mp3Path = [IO.Path]::ChangeExtension($item.Wav.FullName, '.mp3')
        if ($item.Wav.Extension -ieq '.flac') {
            try { $flacConverted = Invoke-FlacMp3Conversion $item.Wav.FullName $mp3Path }
            catch { $flacConverted = $false }
            if (-not $flacConverted) {
                Write-Host "FLAC 转换或校验失败，保留源文件：$($item.Wav.FullName)" -ForegroundColor Red
                $failed++
                continue
            }
        }
        if ((Test-Path -LiteralPath $mp3Path -PathType Leaf) -and (Test-MatchingAudio $item.Wav.FullName $mp3Path)) {
            try {
                $parentDirectory = $item.Wav.DirectoryName
                Remove-Item -LiteralPath $item.Wav.FullName -Force -ErrorAction Stop
                if ($deleteEmptyWavDirectories) {
                    Remove-EmptyParents $parentDirectory $item.Root $wavFolderDeletionBlocked
                }
                $converted++
                $format = $item.Wav.Extension.TrimStart('.').ToLowerInvariant()
                if ($format -eq 'flac') { $deletedFlac++ } else { $deleted++ }
                $record = @{time=(Get-Date).ToString('o');status="converted_320k_${format}_deleted";mp3=$mp3Path}
                $record[$format] = $item.Wav.FullName
                [PSCustomObject]$record |
                    ConvertTo-Json -Compress | Out-File -LiteralPath $logPath -Encoding utf8 -Append
            }
            catch { Write-Host "无损音频删除失败：$($item.Wav.FullName)；$($_.Exception.Message)" -ForegroundColor Red; $failed++ }
        }
        else {
            Write-Host "转换结果校验失败，保留无损音频：$($item.Wav.FullName)" -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host ''
Write-Host '==============================' -ForegroundColor Cyan
Write-Host "采用原生 MP3：$($nativePairs.Count)"
Write-Host "新转换 MP3：$converted"
Write-Host "删除 WAV：$deleted"
Write-Host "删除 FLAC：$deletedFlac"
Write-Host "删除 MP4：$deletedMp4"
Write-Host "删除非原生重复 MP3：$deletedRedundantMp3"
Write-Host "失败：$failed" -ForegroundColor $(if ($failed) {'Red'} else {'Green'})
Write-Host "日志：$logPath"
Write-Host '=============================='
if ($failed) { exit 2 }
exit 0
