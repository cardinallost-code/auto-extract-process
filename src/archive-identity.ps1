# Shared archive identity for extraction, password candidates and project grouping.
# Bare numbers are accepted only as the entire filename stem, never title fragments.
function Get-ArchiveIdentityLeaf([string]$Text) {
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormKC).TrimEnd('\', '/')
    return ($normalized -split '[\\/]')[-1]
}

function Get-RjCode([string]$Text) {
    $leafName = Get-ArchiveIdentityLeaf $Text
    if ($leafName -match '(?i)RJ\D{0,3}([0-9]{8})(?![0-9])') { return "RJ$($Matches[1])" }
    if ($leafName -match '^([0-9]{7,8})(?:\s*\([0-9]+\))?(?:\.[^\\/]*)?$') {
        return "RJ$($Matches[1].PadLeft(8, '0'))"
    }
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormKC)
    if ($normalized -match '(?i)RJ\D{0,3}([0-9]{8})(?![0-9])') { return "RJ$($Matches[1])" }
    return $null
}

function Get-RjCodesFromPath([string]$Text) {
    $codes = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $primary = Get-RjCode $Text
    if ($primary -and $seen.Add($primary)) { $codes.Add($primary) }
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormKC)
    foreach ($match in [regex]::Matches($normalized, '(?i)RJ\D{0,3}([0-9]{8})(?![0-9])')) {
        $code = "RJ$($match.Groups[1].Value)"
        if ($seen.Add($code)) { $codes.Add($code) }
    }
    return @($codes)
}

function Get-ArchiveProjectGroups([string[]]$Paths) {
    $groups = [ordered]@{}
    $unknownIndex = 0
    foreach ($path in $Paths) {
        $key = Get-RjCode $path
        if (-not $key) {
            # Retain legacy explicit 6/7-digit grouping without inventing an identity.
            $leafName = Get-ArchiveIdentityLeaf $path
            if ($leafName -match '(?i)(RJ[0-9]{6,7})(?![0-9])') { $key = $Matches[1].ToUpperInvariant() }
            else { $unknownIndex++; $key = "UNIDENTIFIED_$unknownIndex" }
        }
        if (-not $groups.Contains($key)) { $groups[$key] = [Collections.Generic.List[string]]::new() }
        $groups[$key].Add($path)
    }
    foreach ($key in $groups.Keys) {
        [PSCustomObject]@{ Key=$key; Paths=@($groups[$key].ToArray()) }
    }
}
