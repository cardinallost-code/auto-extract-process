# FLAC uses the same MP3 matching/deletion contract as WAV; desktop WAV tools stay compatible.
function Test-AudioDecode([string]$Path) {
    if ($script:audioDecodeCache.ContainsKey($Path)) { return $script:audioDecodeCache[$Path] }
    $null = & $script:ffmpeg -nostdin -hide_banner -v error -xerror -err_detect explode -i $Path -map 0:a:0 -f null - 2>&1
    $valid = $LASTEXITCODE -eq 0
    $script:audioDecodeCache[$Path] = $valid
    return $valid
}

function Invoke-FlacMp3Conversion([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) {
        return (Test-MatchingAudio $Source $Destination)
    }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.flac_convert_' + [guid]::NewGuid().ToString('N') + '.mp3')
    try {
        $null = & $script:ffmpeg -nostdin -hide_banner -v error -xerror -err_detect explode -i $Source `
            -map 0:a:0 -vn -c:a libmp3lame -b:a 320k -f mp3 $temporary 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary -PathType Leaf)) { return $false }
        # Successful strict conversion decoded the full source already.
        $script:audioDecodeCache[$Source] = $true
        if (-not (Test-MatchingAudio $Source $temporary)) { return $false }
        Move-Item -LiteralPath $temporary -Destination $Destination -ErrorAction Stop
        $script:audioInfoCache.Remove($Destination)
        $script:audioDecodeCache[$Destination] = $true
        return $true
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        $script:audioInfoCache.Remove($temporary)
        $script:audioDecodeCache.Remove($temporary)
    }
}
