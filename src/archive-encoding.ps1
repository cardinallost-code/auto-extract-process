# Detection only reads ZIP entry names. It never extracts or renames files.
function Test-ZipUtf8Metadata([string]$Archive) {
    $stream = [IO.File]::OpenRead($Archive)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $start = [Math]::Max(0, $stream.Length - 65557)
        $stream.Position = $start
        $tail = $reader.ReadBytes([int]($stream.Length - $start))
        for ($i = $tail.Length - 22; $i -ge 0; $i--) {
            if ([BitConverter]::ToUInt32($tail, $i) -ne 0x06054b50) { continue }
            if ($i + 22 + [BitConverter]::ToUInt16($tail, $i + 20) -ne $tail.Length) { continue }
            $count = [BitConverter]::ToUInt16($tail, $i + 10)
            $offset = [BitConverter]::ToUInt32($tail, $i + 16)
            if ($count -eq 0 -or $count -eq 65535 -or $offset -eq [uint32]::MaxValue) { return $false }
            $stream.Position = $offset
            for ($n = 0; $n -lt $count; $n++) {
                $header = $reader.ReadBytes(46)
                if ($header.Length -ne 46 -or [BitConverter]::ToUInt32($header, 0) -ne 0x02014b50) { return $false }
                if (-not ([BitConverter]::ToUInt16($header, 8) -band 0x800)) { return $false }
                $stream.Position += [BitConverter]::ToUInt16($header, 28) + [BitConverter]::ToUInt16($header, 30) + [BitConverter]::ToUInt16($header, 32)
            }
            return $true
        }
        return $false
    } catch { return $false } finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-FilenameEncodingPenalty([string[]]$Names) {
    $score = 0
    foreach ($name in $Names) {
        $score += 20 * [regex]::Matches($name, '[\uFFFD\u0000-\u001F\uE000-\uF8FF]').Count
        # Long runs of half-width kana and recurring mojibake are suspicious, not proof.
        $score += 4 * [regex]::Matches($name, '[\uFF61-\uFF9F]{3,}').Count
        $score += 3 * [regex]::Matches($name, '(?:繝.|縺.|譁.|ã.|Ã.){2,}').Count
        $mojibakeCount = [regex]::Matches($name, '[縺繧繝]').Count
        if ($mojibakeCount -ge 3) { $score += 3 * $mojibakeCount }
    }
    return $score
}

function Resolve-ZipFilenameEncoding([string]$Archive, [int]$DefaultCodePage = 932) {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    if (Test-ZipUtf8Metadata $Archive) {
        return [PSCustomObject]@{ CodePage=65001; Reason='utf8_metadata'; DefaultCodePage=$DefaultCodePage }
    }
    [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($cp in @($DefaultCodePage, 65001, 932, 936, 950 | Select-Object -Unique)) {
        $stream = $null
        $zip = $null
        try {
            $encoding = [Text.Encoding]::GetEncoding($cp, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
            $stream = [IO.File]::OpenRead($Archive)
            $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $false, $encoding)
            # ZipArchive honors each entry's UTF-8 flag ahead of the fallback code page.
            $names = @(foreach ($entry in ($zip.Entries | Select-Object -First 20000)) { $entry.FullName })
            if (@($names | Where-Object { [string]::IsNullOrEmpty($_) }).Count -gt 0 -or ($zip.Entries.Count -gt 0 -and $names.Count -eq 0)) { throw 'Entry name could not be decoded' }
            $candidates.Add([PSCustomObject]@{ CodePage=$cp; Valid=$true; Score=(Get-FilenameEncodingPenalty $names); Names=($names -join "`n") })
        } catch {
            $candidates.Add([PSCustomObject]@{ CodePage=$cp; Valid=$false; Score=1000000; Names='' })
        } finally {
            if ($zip) { $zip.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }
    $baseline = $candidates | Where-Object CodePage -eq $DefaultCodePage | Select-Object -First 1
    $valid = @($candidates | Where-Object Valid | Sort-Object Score)
    $selected = $DefaultCodePage
    $reason = 'default'
    if (-not $baseline.Valid -or $baseline.Score -ge 6) {
        # Equivalent decoded names are not competing interpretations.
        $best = @($valid | Group-Object Names | ForEach-Object { $_.Group | Select-Object -First 1 } | Sort-Object Score)
        if ($best.Count -gt 0 -and $best[0].Score -le 2 -and
            ($best.Count -eq 1 -or $best[1].Score -ge ($best[0].Score + 4))) {
            $selected = [int]$best[0].CodePage
            $reason = 'clear_alternative'
        } else { $reason = 'ambiguous_kept_default' }
    }
    [PSCustomObject]@{ CodePage=$selected; Reason=$reason; DefaultCodePage=$DefaultCodePage }
}

function Get-SelectedArchiveCodePage([string]$Archive) {
    if ((Get-SignatureKind $Archive) -ne 'zip') { return 0 }
    $fallback = if ($config.extraction.PSObject.Properties['zip_filename_code_page']) { [int]$config.extraction.zip_filename_code_page } else { 932 }
    if ($fallback -le 0) { return 0 }
    if ($config.extraction.PSObject.Properties['auto_detect_filename_encoding'] -and -not $config.extraction.auto_detect_filename_encoding) { return $fallback }
    if (-not (Get-Variable archiveEncodingCache -Scope Script -ErrorAction SilentlyContinue)) { $script:archiveEncodingCache = @{} }
    $file = Get-Item -LiteralPath $Archive
    $key = '{0}|{1}|{2}' -f $file.FullName, $file.Length, $file.LastWriteTimeUtc.Ticks
    if (-not $script:archiveEncodingCache.ContainsKey($key)) {
        $decision = Resolve-ZipFilenameEncoding $Archive $fallback
        $script:archiveEncodingCache[$key] = $decision
        if ($decision.Reason -eq 'clear_alternative') {
            Write-Host "文件名编码自动切换：$($file.Name)；$fallback -> $($decision.CodePage)" -ForegroundColor Yellow
        } elseif ($decision.Reason -eq 'ambiguous_kept_default') {
            Write-Warning "文件名编码无法可靠判断，保留 $fallback；建议人工检查：$($file.Name)"
        }
        Write-Result ([PSCustomObject]@{ time=(Get-Date).ToString('o'); status='filename_encoding_selected'; archive=$Archive; code_page=$decision.CodePage; reason=$decision.Reason })
    }
    return [int]$script:archiveEncodingCache[$key].CodePage
}
