function Get-ArchivePartFiles([string]$Archive) {
    $parent = Split-Path -LiteralPath $Archive
    $name = [IO.Path]::GetFileName($Archive)
    $pattern = $null
    if ($name -match '(?i)^(.*)\.part0*1\.(rar|exe|r|e)$') {
        $pattern = '(?i)^{0}\.part\d+\.(rar|exe|r|e)$' -f [regex]::Escape($Matches[1])
    } elseif ($name -match '(?i)^(.*\.(7z|zip))\.0*1$') {
        $pattern = '(?i)^{0}\.\d+$' -f [regex]::Escape($Matches[1])
    }
    if ($pattern) {
        Get-ChildItem -LiteralPath $parent -File -Force | Where-Object {
            $_.Name -match $pattern -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        }
    } elseif (Test-Path -LiteralPath $Archive -PathType Leaf) {
        Get-Item -LiteralPath $Archive
    }
}

function Collapse-PackagingDirectories(
    [string[]]$Roots,
    [ValidateRange(120, 32000)][int]$PathWarningLength = 240
) {
    foreach ($root in @($Roots | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $rootInfo = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Warning "包装层整理已跳过链接目录：$($rootInfo.FullName)"
            continue
        }
        $rootPath = $rootInfo.FullName.TrimEnd('\')
        $rootPrefix = $rootPath + '\'
        $current = $rootInfo

        while ($true) {
            $children = @(Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop)
            $payload = @($children | Where-Object { $_.Name -notlike '.extract_complete*.json' })
            if ($payload.Count -ne 1 -or -not $payload[0].PSIsContainer) { break }
            $wrapper = [IO.DirectoryInfo]$payload[0]
            if ($wrapper.Attributes -band [IO.FileAttributes]::ReparsePoint) { break }
            if (-not $wrapper.FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { break }

            # Identical wrappers must be removed from the inside out; otherwise the
            # inner directory correctly appears as a name conflict with its parent.
            while ($true) {
                $innerItems = @(Get-ChildItem -LiteralPath $wrapper.FullName -Force -ErrorAction Stop |
                    Where-Object { $_.Name -notlike '.extract_complete*.json' })
                if ($innerItems.Count -ne 1 -or -not $innerItems[0].PSIsContainer -or
                    $innerItems[0].Name -ne $wrapper.Name) { break }
                # 进入下一层前检查链接；枚举联接目录的子项会隐藏链接本身，
                # 随后的移动操作可能误动链接目标中的文件。
                if (($innerItems[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    -not $innerItems[0].FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { break }
                $current = $wrapper
                $wrapper = [IO.DirectoryInfo]$innerItems[0]
            }

            $descendants = @(Get-ChildItem -LiteralPath $wrapper.FullName -Recurse -Force -ErrorAction Stop)
            if (@($descendants | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
                Write-Warning "包装层含有链接，保留原结构：$($wrapper.FullName)"
                break
            }
            $normalize = {
                param([string]$value)
                (($value -replace '[^\p{L}\p{Nd}]', '')).ToLowerInvariant()
            }
            $parentName = & $normalize $current.Name
            $wrapperName = & $normalize $wrapper.Name
            $parentRj = [regex]::Match($current.Name, '(?i)RJ\d{6,8}').Value
            $wrapperRj = [regex]::Match($wrapper.Name, '(?i)RJ\d{6,8}').Value
            $sameName = $parentName -and $parentName -eq $wrapperName
            $sameRj = $parentRj -and $wrapperRj -and $parentRj.Equals($wrapperRj, [StringComparison]::OrdinalIgnoreCase)
            $longestPath = @($descendants.FullName + $wrapper.FullName | ForEach-Object { $_.Length } |
                Measure-Object -Maximum).Maximum
            if (-not ($sameName -or $sameRj -or $longestPath -ge $PathWarningLength)) { break }

            $wrapperItems = @(Get-ChildItem -LiteralPath $wrapper.FullName -Force -ErrorAction Stop)
            $moves = [Collections.Generic.List[object]]::new()
            $markerNumber = 0
            $conflict = $null
            foreach ($item in $wrapperItems) {
                $targetName = $item.Name
                $target = Join-Path $current.FullName $targetName
                if (Test-Path -LiteralPath $target) {
                    if ($item.Name -notlike '.extract_complete*.json') {
                        $conflict = $target
                        break
                    }
                    do {
                        $markerNumber++
                        $targetName = ".extract_complete_wrapper_$markerNumber.json"
                        $target = Join-Path $current.FullName $targetName
                    } while (Test-Path -LiteralPath $target)
                }
                $moves.Add([PSCustomObject]@{ Item=$item; Target=$target })
            }
            if ($conflict) {
                Write-Warning "包装层存在同名冲突，保留原结构：$conflict"
                break
            }

            try {
                foreach ($move in $moves) {
                    Move-Item -LiteralPath $move.Item.FullName -Destination $move.Target -ErrorAction Stop
                }
                if (@(Get-ChildItem -LiteralPath $wrapper.FullName -Force).Count -ne 0) {
                    throw "移动后包装目录仍非空"
                }
                Remove-Item -LiteralPath $wrapper.FullName -Force -ErrorAction Stop
                [PSCustomObject]@{
                    status = 'collapsed_packaging_directory'
                    path = $wrapper.FullName
                    destination = $current.FullName
                    reason = $(if ($sameName) { 'same_name' } elseif ($sameRj) { 'same_rj' } else { 'long_path' })
                    previous_longest_path = $longestPath
                }
                $current = $rootInfo
            } catch {
                Write-Warning "包装层整理失败，保留剩余现场：$($wrapper.FullName)；$($_.Exception.Message)"
                break
            }
        }
    }
}

function Repair-CompletedArchiveCleanup([string[]]$Roots, [bool]$DeleteParts) {
    foreach ($root in $Roots) {
        $rootInfo = Get-Item -LiteralPath $root -ErrorAction Stop
        if ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $prefix = $rootInfo.FullName.TrimEnd('\') + '\'
        $directories = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
        foreach ($directory in $directories) {
            # Never follow a junction ancestor or act outside the registered work root.
            $cursor = $directory
            $safe = $directory.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
            while ($safe -and $cursor.FullName -ne $rootInfo.FullName) {
                if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { $safe=$false; break }
                $cursor=$cursor.Parent
            }
            if (-not $safe) { continue }
            $markerPath = Join-Path $directory.FullName '.extract_complete.json'
            if (-not $DeleteParts -or -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
            try {
                $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding utf8 | ConvertFrom-Json
                if (-not $marker.PSObject.Properties['source_name'] -or -not $marker.PSObject.Properties['source_size'] -or -not $marker.PSObject.Properties['completed']) { continue }
                $name = [string]$marker.source_name
                if ($name -ne [IO.Path]::GetFileName($name)) { continue }
                if ($name -notmatch '(?i)\.part0*1\.(rar|exe|r|e)$' -and $name -notmatch '(?i)\.(7z|zip)\.0*1$') { continue }
                if ($directory.Name -notin @((Get-ArchiveBaseName $name), [IO.Path]::GetFileNameWithoutExtension($name))) { continue }
                $firstPath = Join-Path $directory.Parent.FullName $name
                # If a replacement first volume exists, do not trust an old marker.
                if (Test-Path -LiteralPath $firstPath) { continue }
                $remainingParts = @(Get-ArchivePartFiles $firstPath)
                if (@($remainingParts | Where-Object Name -match '(?i)(\.part0*1\.(rar|exe|r|e)|\.(7z|zip)\.0*1)$').Count -gt 0) { continue }
                foreach ($part in $remainingParts) {
                    Remove-Item -LiteralPath $part.FullName -Force -ErrorAction Stop
                    [PSCustomObject]@{status='deleted_completed_split_remainder'; path=$part.FullName; marker=$markerPath}
                }
            } catch { Write-Warning "分卷残留检查失败，保留现场：$markerPath；$($_.Exception.Message)" }
        }
        Repair-SplitCoverWrappers -Root $root
        # Refresh after cover packaging has been removed.
        $directories = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
        # Empty RJ wrappers are extraction artifacts, not arbitrary empty media folders.
        if ($rootInfo.Name -notmatch '^(?i)(RJ\d{8})(?!\d)') { continue }
        $code = $Matches[1]
        foreach ($directory in @($directories | Sort-Object { $_.FullName.Length } -Descending)) {
            if ($directory.Name -ne $code -or -not (Test-Path -LiteralPath $directory.FullName)) { continue }
            $cursor=$directory
            $safe=$true
            while ($cursor.FullName -ne $rootInfo.FullName) {
                if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { $safe=$false; break }
                $cursor=$cursor.Parent
            }
            if ($safe -and @(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
                Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
                [PSCustomObject]@{status='deleted_empty_rj_wrapper'; path=$directory.FullName}
            }
        }
    }
}

function Move-CompletedNumericPackagingResidue([string]$Wrapper, [string]$SourceArchive, [string[]]$FinalDirectories, [string]$QuarantineRoot) {
    if (-not (Test-Path -LiteralPath $Wrapper -PathType Container) -or
        -not (Test-Path -LiteralPath $SourceArchive -PathType Leaf) -or $FinalDirectories.Count -eq 0) { return }
    $wrapperInfo = Get-Item -LiteralPath $Wrapper
    $sourceInfo = Get-Item -LiteralPath $SourceArchive
    if ($wrapperInfo.Attributes -band [IO.FileAttributes]::ReparsePoint -or
        $sourceInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    if ($wrapperInfo.Name -notmatch '^[0-9]{7,8}(?:\s*\([0-9]+\))?$') { return }
    $code = Get-RjCode $sourceInfo.Name
    if (-not $code -or (Get-RjCode $wrapperInfo.Name) -ne $code) { return }
    $wrapperFull = [IO.Path]::GetFullPath($Wrapper).TrimEnd('\')
    $wrapperPrefix = $wrapperFull + '\'
    $hasMainWork = $false
    foreach ($final in $FinalDirectories) {
        $finalFull = [IO.Path]::GetFullPath($final).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $finalFull -PathType Container) -or
            $finalFull.Equals($wrapperFull, [StringComparison]::OrdinalIgnoreCase) -or
            $finalFull.StartsWith($wrapperPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $wrapperFull.StartsWith($finalFull + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
        if (-not (Test-Path -LiteralPath (Join-Path $finalFull '.extract_complete.json') -PathType Leaf)) { return }
        if ((Get-RjCode $finalFull) -eq $code) { $hasMainWork = $true }
    }
    if (-not $hasMainWork) { return }
    $pending = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()
    $pending.Enqueue($wrapperInfo)
    $inventory = [Collections.Generic.List[object]]::new()
    while ($pending.Count) {
        $directory = $pending.Dequeue()
        $markerPath = Join-Path $directory.FullName '.extract_complete.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return }
        try { $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { return }
        if (-not $marker.PSObject.Properties['source_name'] -or
            -not $marker.PSObject.Properties['completed'] -or (Get-RjCode $marker.source_name) -ne $code) { return }
        if ($directory.FullName -eq $wrapperInfo.FullName -and
            ($marker.source_name -ne $sourceInfo.Name -or
             -not $marker.PSObject.Properties['source_size'] -or $marker.source_size -ne $sourceInfo.Length)) { return }
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
            if ($item.PSIsContainer) {
                if ($item.Name -notmatch '^[0-9]{7,8}(?:\s*\([0-9]+\))?$' -or (Get-RjCode $item.Name) -ne $code) { return }
                $pending.Enqueue($item)
            } else {
                # Archive/media/program files keep the wrapper in place. Preserve all attachments.
                if ($item.Name -notlike '.extract_complete*.json' -and $item.Extension -notin @('.txt', '.nfo', '.url')) { return }
                $inventory.Add([PSCustomObject]@{ path=$item.FullName.Substring($wrapperPrefix.Length); size=$item.Length; sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash })
            }
        }
    }
    $quarantineFull = [IO.Path]::GetFullPath($QuarantineRoot).TrimEnd('\')
    if ((Test-Path -LiteralPath $quarantineFull) -and
        (Get-Item -LiteralPath $quarantineFull).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    if ($quarantineFull.Equals($wrapperFull, [StringComparison]::OrdinalIgnoreCase) -or
        $quarantineFull.StartsWith($wrapperPrefix, [StringComparison]::OrdinalIgnoreCase)) { return }
    $target = [IO.Path]::GetFullPath((Join-Path $quarantineFull ($wrapperInfo.Name + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))))
    if (-not $target.StartsWith($quarantineFull + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
    New-Item -ItemType Directory -Path $quarantineFull -Force | Out-Null
    $receipt = [PSCustomObject]@{ time=(Get-Date).ToString('o'); status='quarantined_numeric_packaging'; path=$wrapperFull; destination=$target; source_archive=$sourceInfo.FullName; final_directories=@($FinalDirectories); files=@($inventory.ToArray()) }
    # Save original/target paths and content fingerprints before this reversible move.
    $receipt | ConvertTo-Json -Depth 5 | Out-File -LiteralPath ($target + '.json') -Encoding utf8
    Move-Item -LiteralPath $wrapperFull -Destination $target -ErrorAction Stop
    return $receipt
}

function Repair-SplitCoverWrappers([string]$Root) {
    $rootInfo = Get-Item -LiteralPath $Root
    if ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    if ($rootInfo.Name -notmatch '(?i)^(RJ\d{8})(?!\d)') { return }
    $code = $Matches[1]
    $finalMarker = Join-Path $Root '.extract_complete.json'
    if (-not (Test-Path -LiteralPath $finalMarker -PathType Leaf)) { return }
    try {
        $final = Get-Content -LiteralPath $finalMarker -Raw -Encoding utf8 | ConvertFrom-Json
        if (-not $final.PSObject.Properties['normalized_to_rj'] -or -not $final.normalized_to_rj) { return }
    } catch { return }
    foreach ($wrapper in @(Get-ChildItem -LiteralPath $Root -Directory -Force)) {
        if ($wrapper.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $markerPath = Join-Path $wrapper.FullName '.extract_complete.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding utf8 | ConvertFrom-Json
            if (-not $marker.PSObject.Properties['source_name'] -or -not $marker.PSObject.Properties['completed']) { continue }
            $name = [string]$marker.source_name
            if ($name -ne [IO.Path]::GetFileName($name) -or $name -notmatch '(?i)\.part0*1\.(exe|rar|r|e)$') { continue }
            if ($name -notmatch ('(?i)^{0}(?!\d)' -f [regex]::Escape($code))) { continue }
            $base = Get-ArchiveBaseName $name
            $legacy = [IO.Path]::GetFileNameWithoutExtension($name)
            if ($wrapper.Name -notin @($base, $legacy)) { continue }
            $items = @(Get-ChildItem -LiteralPath $wrapper.FullName -Recurse -Force)
            if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { continue }
            # Only collapse a known wrapper chain containing covers and this tool's marker.
            # Language/audio directories and every other non-cover file are protected.
            $subdirs = @($items | Where-Object PSIsContainer)
            if (@($subdirs | Where-Object { $_.Name -notin @($base, $legacy) }).Count) { continue }
            $files = @($items | Where-Object { -not $_.PSIsContainer })
            if (@($files | Where-Object { $_.FullName -ne $markerPath -and $_.Name -notmatch '(?i)^cover\.(jpg|jpeg|png|webp)$' }).Count) { continue }
            $covers = @($files | Where-Object FullName -ne $markerPath)
            $targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $conflict = $false
            foreach ($cover in $covers) {
                $target = Join-Path $Root $cover.Name
                if ((Test-Path -LiteralPath $target) -or -not $targets.Add($target)) { $conflict=$true; break }
            }
            if ($conflict) { Write-Warning "封面同名冲突，保留包装层：$($wrapper.FullName)"; continue }
            foreach ($cover in $covers) {
                $target = Join-Path $Root $cover.Name
                Move-Item -LiteralPath $cover.FullName -Destination $target -ErrorAction Stop
                [PSCustomObject]@{status='moved_wrapper_cover'; path=$cover.FullName; destination=$target}
            }
            foreach ($directory in @($subdirs | Sort-Object { $_.FullName.Length } -Descending)) {
                if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
                }
            }
            # Never recursively delete a directory; recheck after every move.
            $remaining = @(Get-ChildItem -LiteralPath $wrapper.FullName -Force)
            if ($remaining.Count -eq 1 -and $remaining[0].FullName -eq $markerPath) {
                Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
                Remove-Item -LiteralPath $wrapper.FullName -Force -ErrorAction Stop
                [PSCustomObject]@{status='deleted_split_cover_wrapper'; path=$wrapper.FullName; completion=$marker}
            }
        } catch { Write-Warning "包装层整理失败，保留剩余现场：$($_.Exception.Message)" }
    }
}
