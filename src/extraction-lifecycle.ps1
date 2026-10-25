# Extraction completion and cleanup are independent of RJ naming.
function Test-ArchiveSourceMarker([string]$Marker, [string]$Archive) {
    try {
        $receipt=Get-Content -LiteralPath $Marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $source=Get-Item -LiteralPath $Archive -Force -ErrorAction Stop
        return [bool]($receipt.PSObject.Properties['source_name'] -and $receipt.source_name -eq $source.Name -and
            $receipt.PSObject.Properties['source_size'] -and $receipt.source_size -eq $source.Length -and
            $receipt.PSObject.Properties['source_modified_ticks'] -and [string]$receipt.source_modified_ticks -eq [string]$source.LastWriteTimeUtc.Ticks)
    } catch { return $false }
}

function Assert-ExtractionTree([string]$Root) {
    $info = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    $ancestor = $info
    while ($ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "解压路径包含链接：$($ancestor.FullName)" }
        $ancestor=$ancestor.Parent
    }
    if (-not $info.PSIsContainer -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "解压目录不是普通目录：$Root"
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $info.FullName -Force -Recurse -ErrorAction Stop)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "解压目录含链接，保留现场：$($item.FullName)" }
    }
    return $info.FullName.TrimEnd('\')
}

function Merge-ExtractionPayload([string]$PayloadDirectory, [string]$FinalDirectory, [string]$FinalArchive, [bool]$CollapseSingleDirectories = $true) {
    try {
        $payload = Assert-ExtractionTree $PayloadDirectory
        $final = [IO.Path]::GetFullPath($FinalDirectory).TrimEnd('\')
        if ($payload.Equals($final, [StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{ Success=$true; Reason=''; DuplicateCount=0 }
        }
        if ($final.StartsWith($payload + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $payload.StartsWith($final + '\', [StringComparison]::OrdinalIgnoreCase)) {
            # The target may be an ancestor wrapper (the common nested-RJ case).
            if ($final.StartsWith($payload + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '最终目录位于待提交内容内部' }
        }
        if (Test-Path -LiteralPath $final) { [void](Assert-ExtractionTree $final) }
        else {
            $ancestor = [IO.Directory]::GetParent($final)
            while ($ancestor -and -not $ancestor.Exists) { $ancestor=$ancestor.Parent }
            if ($ancestor -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '最终目录父级为链接' }
        }
        # Strip a single packaging chain, but retain the level that matches an existing payload.
        $payloadRoot = $payload
        while ($CollapseSingleDirectories) {
            $items = @(Get-ChildItem -LiteralPath $payloadRoot -Force | Where-Object {
                $_.FullName -ne $FinalArchive -and $_.Name -notlike '.extract_complete*.json'
            })
            if ($items.Count -ne 1 -or -not $items[0].PSIsContainer -or
                (Test-Path -LiteralPath (Join-Path $final $items[0].Name))) { break }
            $payloadRoot=$items[0].FullName
        }
        $files = @(Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force | Where-Object {
            $_.FullName -ne $FinalArchive -and $_.Name -notlike '.extract_complete*.json'
        })
        if ($files.Count -eq 0) { throw '没有找到可提交的最终作品内容' }
        $moves = [Collections.Generic.List[object]]::new()
        # Preflight the entire tree before moving or deleting any payload file.
        foreach ($file in $files) {
            $relative=[IO.Path]::GetRelativePath($payloadRoot,$file.FullName)
            $target=Join-Path $final $relative
            $duplicate=$false
            if (Test-Path -LiteralPath $target) {
                $existing=Get-Item -LiteralPath $target -Force
                if ($existing.PSIsContainer -or $existing.Length -ne $file.Length -or
                    (Get-FileHash -LiteralPath $existing.FullName -Algorithm SHA256).Hash -ne
                    (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
                    throw "最终目录内容冲突，双方均保留：$target"
                }
                $duplicate=$true
            }
            $parent=[IO.Directory]::GetParent($target)
            while ($parent -and -not $parent.FullName.Equals($final,[StringComparison]::OrdinalIgnoreCase)) {
                if ((Test-Path -LiteralPath $parent.FullName) -and
                    -not (Test-Path -LiteralPath $parent.FullName -PathType Container)) { throw "最终目录类型冲突：$($parent.FullName)" }
                $parent=$parent.Parent
            }
            $moves.Add([PSCustomObject]@{Source=$file.FullName;Target=$target;Duplicate=$duplicate})
        }
        foreach ($move in $moves) {
            if ($move.Duplicate) { Remove-Item -LiteralPath $move.Source -Force -ErrorAction Stop }
            else {
                New-Item -ItemType Directory -Path (Split-Path -LiteralPath $move.Target) -Force | Out-Null
                Move-Item -LiteralPath $move.Source -Destination $move.Target -ErrorAction Stop
            }
        }
        return [PSCustomObject]@{Success=$true;Reason='';DuplicateCount=@($moves | Where-Object Duplicate).Count}
    } catch { return [PSCustomObject]@{Success=$false;Reason=$_.Exception.Message;DuplicateCount=0} }
}

function Remove-CompletedPackagingTrees([string[]]$Roots, [string[]]$FinalDirectories) {
    $finals=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($final in $FinalDirectories) { [void]$finals.Add([IO.Path]::GetFullPath($final).TrimEnd('\')) }
    foreach ($root in @($Roots | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try { $rootFull=Assert-ExtractionTree $root }
        catch { throw }
        $directories=@(Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force) + @(Get-Item -LiteralPath $rootFull)
        $wrapperRoots=[Collections.Generic.List[string]]::new()
        # Outside final work roots, these are explicitly registered discarded extraction trees.
        if (-not $finals.Contains($rootFull)) { $wrapperRoots.Add($rootFull) }
        foreach ($directory in $directories) {
            if ($finals.Contains($directory.FullName.TrimEnd('\'))) { continue }
            $ownMarkers=@(Get-ChildItem -LiteralPath $directory.FullName -File -Force -Filter '.extract_complete*.json')
            if ($ownMarkers.Count -and @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -Force |
                Where-Object { $_.Name -notlike '.extract_complete*.json' }).Count -eq 0) {
                $wrapperRoots.Add($directory.FullName.TrimEnd('\'))
            }
        }
        foreach ($directory in @($directories | Sort-Object { $_.FullName.Length } -Descending)) {
            $path=[IO.Path]::GetFullPath($directory.FullName).TrimEnd('\')
            if ($finals.Contains($path)) { continue }
            if (-not $path.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -and
                -not $path.StartsWith($rootFull+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '包装清理路径越界' }
            $isWrapper=$false
            foreach ($wrapper in $wrapperRoots) {
                if ($path.Equals($wrapper,[StringComparison]::OrdinalIgnoreCase) -or
                    $path.StartsWith($wrapper+'\',[StringComparison]::OrdinalIgnoreCase)) { $isWrapper=$true;break }
            }
            if (-not $isWrapper) { continue }
            $remaining=@(Get-ChildItem -LiteralPath $path -Force)
            if (@($remaining | Where-Object { $_.PSIsContainer -or $_.Name -notlike '.extract_complete*.json' }).Count) { continue }
            # Yield the original markers to the caller's durable log before removing them.
            $proof=@($remaining | ForEach-Object { @{name=$_.Name;content=(Get-Content -LiteralPath $_.FullName -Raw)} })
            [PSCustomObject]@{status='packaging_cleanup_planned';path=$path;completion=$proof}
            foreach ($marker in $remaining) { Remove-Item -LiteralPath $marker.FullName -Force -ErrorAction Stop }
            if (@(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                [PSCustomObject]@{status='deleted_completed_packaging';path=$path}
            }
        }
    }
}
