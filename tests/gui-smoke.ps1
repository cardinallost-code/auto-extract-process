# Executed only by extract-gui.ps1 -StartupTest. All execution uses a temporary fake worker.
function Assert-Gui([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "GUI regression: $Message" }
}
function Wait-GuiWorker {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($script:activeProcess -and $watch.Elapsed.TotalSeconds -lt 15) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }
    Assert-Gui (-not $script:activeProcess) 'worker did not complete'
}
function Assert-GuiLayout {
    [Windows.Forms.Application]::DoEvents()
    foreach ($control in @($start, $stop, $status, $elapsedLabel, $progressLabel, $overallProgress, $addFolder, $addFiles, $removeInput, $clearInputs, $outputBrowse, $openOutput)) {
        Assert-Gui ($control.Bounds.Right -le $control.Parent.ClientSize.Width + 1) ("clipped right: " + $control.Text)
        Assert-Gui ($control.Bounds.Bottom -le $control.Parent.ClientSize.Height + 1) ("clipped bottom: $($control.Text); bounds=$($control.Bounds); parent=$($control.Parent.ClientSize)")
    }
    Assert-Gui ($status.Right -le $elapsedLabel.Left) 'status overlaps elapsed time'
    Assert-Gui ($workspace.Panel2.Width -ge 400) 'log column is too narrow'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('extract-gui-test-' + [Guid]::NewGuid().ToString('N'))
$originalSettings = $guiSettingsPath
$originalWorker = $extractScript
$originalOutput = $outputBox.Text
$originalSize = $form.ClientSize
$originalLog = $log.Text
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $guiSettingsPath = Join-Path $testRoot 'gui-settings.json'
    $extractScript = Join-Path $testRoot 'fake-worker.ps1'
    $inputFile = Join-Path $testRoot '测试 音频包.zip'
    $secondFile = Join-Path $testRoot '另一个 分卷.001'
    [IO.File]::WriteAllText($inputFile, 'GUI fixture only')
    [IO.File]::WriteAllText($secondFile, 'GUI fixture only')
    Add-Inputs @($inputFile, $secondFile, $inputFile)
    Assert-Gui ($inputList.Items.Count -eq 2) 'Unicode inputs or duplicate rejection failed'
    Assert-Gui (-not $emptyInput.Visible -and $inputList.Visible) 'empty state did not disappear'
    $inputList.SelectedIndex = 0
    Assert-Gui ($selectionHint.Text -eq $inputFile) 'full source path is unavailable'

    Set-ProjectProgress 0 4
    Update-ProgressFromLog '========== 阶段 1/3：递归解压 =========='
    Update-ProgressFromLog '[RJ00000001] 结束：退出代码 0'
    Update-ProgressFromLog '[RJ00000002] 结束：退出代码 2'
    Assert-Gui ($overallProgress.Value -eq 2) 'archive groups were not counted'
    Update-ProgressFromLog '========== 阶段 2/3：文件处理 =========='
    Assert-Gui ($overallProgress.Style -eq 'Marquee') 'audio processing looks complete'
    Assert-Gui ($script:stageStates[0] -eq '部分失败') 'archive failure was hidden'
    Update-ProgressFromLog '========== 阶段 3/3：作品名称补全 =========='
    Complete-RunDisplay 2 $false
    Set-Busy $false
    Assert-Gui ($status.Text -match '未完成项') 'partial failure reset to ready'
    Assert-Gui ($script:stageStates[2] -eq '完成') 'successful naming was marked failed'
    Assert-Gui ($overallProgress.Value -eq 0) 'partial failure displays full progress'

    Reset-RunDisplay
    Set-CurrentStage 1
    Set-CurrentStage 2
    Set-CurrentStage 3
    Update-ProgressFromLog '解压和文件处理完成，部分作品名称待补全。可单独重试第三阶段。'
    Complete-RunDisplay 2 $false
    Assert-Gui ($status.Text -match '名称待补全') 'naming failure classification'
    Assert-Gui ($script:stageStates[0] -eq '完成') 'naming failure corrupted extraction state'

    $outputBox.Text = $testRoot
    $customRadio.Checked = $true
    $worker = @'
[CmdletBinding()]
param([Parameter(Position=0, ValueFromRemainingArguments=$true)][string[]]$InputPath, [switch]$Run, [switch]$ExtractToSource, [string]$OutputRoot)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
@{run=[bool]$Run; source=[bool]$ExtractToSource; output=$OutputRoot; inputs=$InputPath} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'args.json') -Encoding utf8
Write-Output '========== 阶段 1/3：递归解压 =========='
Write-Output '并行项目：2 组；同时运行：2'
Write-Output '[RJ00000001] 结束：退出代码 0'
Write-Output '[RJ00000002] 结束：退出代码 0'
Write-Output '========== 阶段 2/3：文件处理 =========='
Write-Output '========== 阶段 3/3：作品名称补全 =========='
Write-Output '一键流水线全部完成。'
exit 0
'@
    [IO.File]::WriteAllText($extractScript, $worker, [Text.UTF8Encoding]::new($false))
    $start.PerformClick()
    Assert-Gui ($null -ne $script:activeProcess) 'start button did not launch worker'
    Add-Inputs @($testRoot)
    Assert-Gui ($inputList.Items.Count -eq 2) 'input queue changed during execution'
    Assert-Gui (-not $clearLog.Enabled -and -not $inputList.AllowDrop -and $stop.Enabled) 'busy controls'
    Wait-GuiWorker
    $arguments = Get-Content -LiteralPath (Join-Path $testRoot 'args.json') -Raw | ConvertFrom-Json
    Assert-Gui ($arguments.run -and $arguments.output -eq $testRoot) 'Run or output arguments changed'
    Assert-Gui ($arguments.inputs.Count -eq 2 -and $arguments.inputs[0] -eq $inputFile) 'Unicode positional inputs changed'
    Assert-Gui ($status.Text -match '^全部完成') 'successful process did not preserve final status'
    Assert-Gui ($overallProgress.Value -eq $overallProgress.Maximum) 'success progress'

    $sourceRadio.Checked = $true
    $start.PerformClick()
    Wait-GuiWorker
    $arguments = Get-Content -LiteralPath (Join-Path $testRoot 'args.json') -Raw | ConvertFrom-Json
    Assert-Gui ($arguments.source -and -not $arguments.output) 'source mode arguments changed'
    Assert-Gui (-not $outputBox.Enabled) 'source mode still allows custom output editing'

    $partialWorker = $worker.Replace("Write-Output '一键流水线全部完成。'", "Write-Output '解压阶段有部分项目失败；成功解压的作品将继续执行文件处理。'").Replace('exit 0', 'exit 2')
    [IO.File]::WriteAllText($extractScript, $partialWorker, [Text.UTF8Encoding]::new($false))
    $start.PerformClick()
    Wait-GuiWorker
    Assert-Gui ($status.Text -match '未完成项' -and $script:stageStates[0] -eq '部分失败') ("exit 2 final result: $($status.Text); stages=$($script:stageStates -join ','); log=$($log.Text)")

    $slowWorker = $worker.Replace("Write-Output '并行项目：2 组；同时运行：2'", 'Start-Sleep -Seconds 30')
    [IO.File]::WriteAllText($extractScript, $slowWorker, [Text.UTF8Encoding]::new($false))
    $start.PerformClick()
    $stageWait = [Diagnostics.Stopwatch]::StartNew()
    while ($script:currentStage -eq 0 -and $stageWait.Elapsed.TotalSeconds -lt 5) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }
    $stop.PerformClick()
    Wait-GuiWorker
    Assert-Gui ($status.Text -match '^已停止') 'stop result disappeared'
    Assert-Gui ($script:stageStates[1] -eq '等待') 'unstarted stage marked completed'

    Assert-GuiLayout
    $form.Size = $form.MinimumSize
    Assert-GuiLayout
    $form.ClientSize = $originalSize
    $form.Scale([Drawing.SizeF]::new(1.25, 1.25))
    Assert-GuiLayout
    $form.Scale([Drawing.SizeF]::new(0.8, 0.8))
    $form.ClientSize = $originalSize
    Write-Output 'GUI_SMOKE_OK: Unicode inputs, custom/source dispatch, busy locks, stage progress, success/partial/naming/stop states, minimum/scaled layout.'
} finally {
    if ($script:activeProcess) {
        try { $script:activeProcess.Kill($true); $script:activeProcess.WaitForExit() } catch {}
        $script:activeProcess.Dispose()
        $script:activeProcess = $null
    }
    $guiSettingsPath = $originalSettings
    $extractScript = $originalWorker
    $outputBox.Text = $originalOutput
    $customRadio.Checked = $true
    $inputList.Items.Clear()
    $script:projectCompleted.Clear()
    $script:elapsedWatch.Reset()
    $script:stopRequested = $false
    Update-ElapsedLabel
    Reset-RunDisplay
    Set-Busy $false
    Update-InputSummary
    $progressLabel.Text = '等待开始'
    $status.Text = '就绪 · 添加输入后开始处理'
    $log.Clear()
    Add-Log $originalLog.TrimEnd() ([Drawing.Color]::Khaki)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($resolvedTest)).StartsWith('extract-gui-test-')) {
        throw 'Refusing to remove unexpected GUI test directory'
    }
    Remove-Item -LiteralPath $resolvedTest -Recurse -Force
}
