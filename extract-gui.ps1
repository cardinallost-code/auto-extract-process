#requires -Version 7.0

[CmdletBinding()]
param([switch]$HideConsole, [switch]$StartupTest, [string]$ScreenshotPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'src\archive-identity.ps1')

$extractScript = Join-Path $PSScriptRoot "processing-pipeline.ps1"
$errorLog = Join-Path $PSScriptRoot "extract-gui-error.log"
$guiSettingsPath = Join-Path $PSScriptRoot "gui-settings.json"

trap {
    if ($StartupTest) {
        [Console]::Error.WriteLine($_.Exception.ToString())
        [Console]::Error.WriteLine($_.ScriptStackTrace)
        exit 1
    }
    $_.Exception.ToString() | Out-File -LiteralPath $errorLog -Encoding utf8
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show("解压界面启动失败：`r`n$($_.Exception.Message)`r`n`r`n$errorLog", "自动解压处理工具", "OK", "Error")
    } catch {}
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

if ($HideConsole) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ExtractGuiConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    $consoleHandle = [ExtractGuiConsole]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) { [void][ExtractGuiConsole]::ShowWindow($consoleHandle, 0) }
}

$script:activeProcess = $null
$script:stdoutLineTask = $null
$script:stderrLineTask = $null
$script:stopRequested = $false
$script:elapsedWatch = [Diagnostics.Stopwatch]::new()
$script:projectTotal = 0
$script:projectCompleted = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
. (Join-Path $PSScriptRoot 'src\extract-gui-layout.ps1')
. (Join-Path $PSScriptRoot 'src\extract-gui-state.ps1')

function Add-Log([string]$Text, [Drawing.Color]$Color = [Drawing.Color]::Gainsboro) {
    $Text = $Text -replace '\x1B\[[0-9;]*m', ''
    if (-not $PSBoundParameters.ContainsKey('Color')) {
        if ($Text -match '失败|异常|错误|待补全') { $Color = [Drawing.Color]::LightSalmon }
        elseif ($Text -match '^========== 阶段') { $Color = [Drawing.Color]::LightSkyBlue }
        elseif ($Text -match '一键流水线全部完成') { $Color = [Drawing.Color]::LightGreen }
    }
    $action = {
        $log.SelectionStart = $log.TextLength
        $log.SelectionColor = $Color
        $log.AppendText($Text + [Environment]::NewLine)
        $log.ScrollToCaret()
    }
    if ($form.InvokeRequired) { [void]$form.BeginInvoke($action) } else { & $action }
}

function Add-Inputs([string[]]$Paths) {
    if ($script:activeProcess) { return }
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path) {
            $resolved = (Resolve-Path -LiteralPath $path).Path
            if (-not $inputList.Items.Contains($resolved)) { [void]$inputList.Items.Add($resolved) }
        }
    }
    Update-InputSummary
}

function Get-ProjectGroupCount {
    $paths = @($inputList.Items | ForEach-Object { [string]$_ })
    return [Math]::Max(1, @(Get-ArchiveProjectGroups $paths).Count)
}

function Set-ProjectProgress([int]$Completed, [int]$Total) {
    $script:projectTotal = [Math]::Max(1, $Total)
    $safeCompleted = [Math]::Min([Math]::Max(0, $Completed), $script:projectTotal)
    $overallProgress.Maximum = $script:projectTotal
    $overallProgress.Value = $safeCompleted
    if ($script:currentStage -le 1) {
        $progressLabel.Text = "解压分组 $safeCompleted/$($script:projectTotal) 已结束"
    }
}

function Update-ProgressFromLog([string]$Line) {
    # PowerShell may emit ANSI colors even through a redirected stream.
    $Line = $Line -replace '\x1B\[[0-9;]*m', ''
    if ($Line -match '^========== 阶段 ([123])/3：') {
        Set-CurrentStage ([int]$Matches[1])
        return
    }
    if ($Line -match '解压阶段有部分项目失败|仍有压缩包解压失败') {
        $script:extractionHasFailures = $true
        $script:stageStates[0] = '部分失败'
        Update-StageLabels
    }
    if ($Line -match '部分作品名称待补全') {
        $script:namingHasFailures = $true
    }
    if ($Line -match '^并行项目：(\d+) 组') {
        Set-ProjectProgress $script:projectCompleted.Count ([int]$Matches[1])
        return
    }
    if ($Line -match '^\[([^\]]+)\] 结束：退出代码 (\d+)') {
        if ([int]$Matches[2] -ne 0) { $script:extractionHasFailures = $true }
        [void]$script:projectCompleted.Add($Matches[1])
        Set-ProjectProgress $script:projectCompleted.Count $script:projectTotal
        return
    }
}

function Update-ElapsedLabel {
    $elapsed = $script:elapsedWatch.Elapsed
    $elapsedLabel.Text = "耗时 {0:00}:{1:00}:{2:00}" -f `
        [Math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds
}

function Save-GuiSettings {
    $settings = [PSCustomObject]@{
        output_mode = if ($customRadio.Checked) { 'custom' } else { 'source' }
        output_root = $outputBox.Text.Trim()
    }
    [IO.File]::WriteAllText($guiSettingsPath, ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

if (Test-Path -LiteralPath $guiSettingsPath -PathType Leaf) {
    try {
        $savedSettings = Get-Content -LiteralPath $guiSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($savedSettings.output_root -and (Test-Path -LiteralPath ([string]$savedSettings.output_root) -PathType Container)) {
            $outputBox.Text = [string]$savedSettings.output_root
        }
    } catch {}
}

function Set-Busy([bool]$Busy) {
    $action = {
        $start.Enabled = -not $Busy
        $stop.Enabled = $Busy
        $addFolder.Enabled = -not $Busy
        $addFiles.Enabled = -not $Busy
        $removeInput.Enabled = -not $Busy
        $clearInputs.Enabled = -not $Busy
        $sourceRadio.Enabled = -not $Busy
        $customRadio.Enabled = -not $Busy
        $outputBox.Enabled = (-not $Busy -and $customRadio.Checked)
        $outputBrowse.Enabled = (-not $Busy -and $customRadio.Checked)
        $clearLog.Enabled = -not $Busy
        $form.AllowDrop = -not $Busy
        $inputList.AllowDrop = -not $Busy
        $emptyInput.AllowDrop = -not $Busy
        $start.Text = if ($Busy) { '处理中…' } else { '开始处理' }
        if ($Busy) { $status.Text = '正在启动处理…' }
    }
    if ($form.InvokeRequired) { [void]$form.BeginInvoke($action) } else { & $action }
}

$processTimer = [Windows.Forms.Timer]::new()
$processTimer.Interval = 100
$processTimer.Add_Tick({
    if (-not $script:activeProcess) { return }
    Update-ElapsedLabel

    # 在 UI 主线程逐行收取异步输出，既实时显示，也避免跨线程操作 WinForms。
    for ($lineIndex = 0; $lineIndex -lt 100 -and $script:stdoutLineTask -and $script:stdoutLineTask.IsCompleted; $lineIndex++) {
        try { $line = $script:stdoutLineTask.GetAwaiter().GetResult() } catch { $line = $null }
        if ($null -eq $line) { $script:stdoutLineTask = $null; break }
        Update-ProgressFromLog $line
        Add-Log $line
        $script:stdoutLineTask = $script:activeProcess.StandardOutput.ReadLineAsync()
    }
    for ($lineIndex = 0; $lineIndex -lt 100 -and $script:stderrLineTask -and $script:stderrLineTask.IsCompleted; $lineIndex++) {
        try { $line = $script:stderrLineTask.GetAwaiter().GetResult() } catch { $line = $null }
        if ($null -eq $line) { $script:stderrLineTask = $null; break }
        Update-ProgressFromLog $line
        Add-Log $line ([Drawing.Color]::LightCoral)
        $script:stderrLineTask = $script:activeProcess.StandardError.ReadLineAsync()
    }

    if (-not $script:activeProcess.HasExited -or $script:stdoutLineTask -or $script:stderrLineTask) { return }

    $processTimer.Stop()
    try {
        $script:activeProcess.WaitForExit()
        $exitCode = $script:activeProcess.ExitCode
        $script:elapsedWatch.Stop()
        Update-ElapsedLabel
        Complete-RunDisplay $exitCode $script:stopRequested
        $endMessage = if ($script:stopRequested) { "任务已由用户停止" } else { "处理结束，退出代码：$exitCode" }
        Add-Log $endMessage $(if ($exitCode -eq 0) { [Drawing.Color]::LightGreen } else { [Drawing.Color]::LightCoral })
    }
    catch {
        Add-Log "读取处理结果失败：$($_.Exception.Message)" ([Drawing.Color]::LightCoral)
        Complete-RunDisplay -1 $script:stopRequested
    }
    finally {
        $script:activeProcess.Dispose()
        $script:activeProcess = $null
        $script:stdoutLineTask = $null
        $script:stderrLineTask = $null
        $script:stopRequested = $false
        Set-Busy $false
    }
})

$addFolder.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "选择包含压缩包的文件夹"
    if ($dialog.ShowDialog($form) -eq "OK") { Add-Inputs @($dialog.SelectedPath) }
    $dialog.Dispose()
})

$addFiles.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = "选择一个或多个压缩文件"
    $dialog.Multiselect = $true
    $dialog.Filter = "压缩文件及自解压包|*.7z;*.zip;*.rar;*.exe;*.001;*.gz;*.tar;*.*|所有文件|*.*"
    if ($dialog.ShowDialog($form) -eq "OK") { Add-Inputs $dialog.FileNames }
    $dialog.Dispose()
})

$removeInput.Add_Click({
    @($inputList.SelectedItems) | ForEach-Object { $inputList.Items.Remove($_) }
    Update-InputSummary
})
$clearInputs.Add_Click({ $inputList.Items.Clear(); Update-InputSummary })

$customRadio.Add_CheckedChanged({
    $outputBox.Enabled = $customRadio.Checked
    $outputBrowse.Enabled = $customRadio.Checked
})

$outputBrowse.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "选择统一解压输出文件夹"
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog($form) -eq "OK") {
        $outputBox.Text = $dialog.SelectedPath
        Save-GuiSettings
    }
    $dialog.Dispose()
})

$dragEnter = {
    param($sender, $eventArgs)
    if (-not $script:activeProcess -and $eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
    }
}
$dragDrop = {
    param($sender, $eventArgs)
    Add-Inputs @($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
}
$form.Add_DragEnter($dragEnter)
$form.Add_DragDrop($dragDrop)
$inputList.AllowDrop = $true
$inputList.Add_DragEnter($dragEnter)
$inputList.Add_DragDrop($dragDrop)
$emptyInput.AllowDrop = $true
$emptyInput.Add_DragEnter($dragEnter)
$emptyInput.Add_DragDrop($dragDrop)

$start.Add_Click({
    if ($inputList.Items.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show("请先拖入压缩文件或文件夹。", "没有输入", "OK", "Warning")
        return
    }
    if ($customRadio.Checked -and [string]::IsNullOrWhiteSpace($outputBox.Text)) {
        [void][Windows.Forms.MessageBox]::Show("请选择输出文件夹。", "没有输出目录", "OK", "Warning")
        return
    }
    if ($customRadio.Checked -and -not (Test-Path -LiteralPath $outputBox.Text.Trim() -PathType Container)) {
        [void][Windows.Forms.MessageBox]::Show("指定的输出文件夹不存在，请重新选择。", "输出目录无效", "OK", "Warning")
        return
    }
    Save-GuiSettings

    $log.Clear()
    Reset-RunDisplay
    Show-ProcessingRules
    $script:projectCompleted.Clear()
    Set-ProjectProgress 0 (Get-ProjectGroupCount)
    $script:elapsedWatch.Restart()
    Update-ElapsedLabel
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command pwsh.exe).Source
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Environment["PYTHONUTF8"] = "1"
    $info.Environment["PYTHONIOENCODING"] = "utf-8"
    foreach ($argument in @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $extractScript)) {
        [void]$info.ArgumentList.Add($argument)
    }
    # 单一工作流：点击后始终直接执行，不再区分预演/实操。
    [void]$info.ArgumentList.Add("-Run")
    if ($sourceRadio.Checked) {
        [void]$info.ArgumentList.Add("-ExtractToSource")
    } else {
        [void]$info.ArgumentList.Add("-OutputRoot")
        [void]$info.ArgumentList.Add($outputBox.Text.Trim())
    }
    # pwsh -File 不能用一个命名数组参数承接多个独立 argv。
    # 所有开关必须在前，路径作为最后的连续位置参数由 ValueFromRemainingArguments 接收。
    foreach ($item in $inputList.Items) { [void]$info.ArgumentList.Add([string]$item) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "无法启动解压进程" }
        $script:activeProcess = $process
        $script:stopRequested = $false
        $script:stdoutLineTask = $process.StandardOutput.ReadLineAsync()
        $script:stderrLineTask = $process.StandardError.ReadLineAsync()
        Set-Busy $true
        $processTimer.Start()
    } catch {
        $script:elapsedWatch.Stop()
        Update-ElapsedLabel
        Add-Log "启动失败：$($_.Exception.Message)" ([Drawing.Color]::LightCoral)
        Complete-RunDisplay -1 $false
        Set-Busy $false
    }
})

$stop.Add_Click({
    if ($script:activeProcess -and -not $script:activeProcess.HasExited) {
        try {
            $script:stopRequested = $true
            $script:activeProcess.Kill($true)
        } catch { Add-Log $_.Exception.Message ([Drawing.Color]::LightCoral) }
    }
})
$clearLog.Add_Click({ $log.Clear() })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:activeProcess -and -not $script:activeProcess.HasExited) {
        $answer = [Windows.Forms.MessageBox]::Show("解压仍在运行，是否停止并关闭？", "确认关闭", "YesNo", "Warning")
        if ($answer -ne "Yes") { $eventArgs.Cancel = $true; return }
        try { $script:activeProcess.Kill($true) } catch {}
    }
})

Add-Log -Text '拖入文件或文件夹，点击开始处理后直接执行完整工作流。默认输出到指定文件夹，选定路径会自动保存。' -Color ([Drawing.Color]::Khaki)
if ($StartupTest) {
    if (-not $log.Text.Contains('默认输出到指定文件夹')) { throw '界面启动提示写入失败' }
    $form.StartPosition = 'Manual'
    $form.Location = [Drawing.Point]::new(-20000, -20000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    . (Join-Path $PSScriptRoot 'tests\gui-smoke.ps1')
    if ($ScreenshotPath) {
        $bitmap = [Drawing.Bitmap]::new($form.Width, $form.Height)
        try {
            $form.DrawToBitmap($bitmap, [Drawing.Rectangle]::new(0, 0, $form.Width, $form.Height))
            $bitmap.Save($ScreenshotPath, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
    }
    $form.Dispose()
    exit 0
}
[void]$form.ShowDialog()
