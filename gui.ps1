#requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$HideConsole
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$pipelineScript = Join-Path $PSScriptRoot "process.ps1"
$configPath = Join-Path $PSScriptRoot "config.json"
$errorLogPath = Join-Path $PSScriptRoot "gui-error.log"

trap {
    $message = $_.Exception.ToString()
    $message | Out-File -LiteralPath $errorLogPath -Encoding utf8
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show(
            "界面启动失败：`r`n`r`n$($_.Exception.Message)`r`n`r`n错误日志：$errorLogPath",
            "自动解压处理工具",
            "OK",
            "Error"
        )
    }
    catch {}
    exit 1
}

function Read-AppConfig {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "找不到配置文件：$configPath"
    }
    Get-Content -LiteralPath $configPath -Raw -Encoding utf8 |
        ConvertFrom-Json -ErrorAction Stop
}

if ($SelfTest) {
    $config = Read-AppConfig
    if (-not (Test-Path -LiteralPath $pipelineScript -PathType Leaf)) {
        throw "找不到处理脚本：$pipelineScript"
    }
    if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        throw "找不到 PowerShell 7（pwsh.exe）"
    }
    Write-Output "GUI dependencies: OK"
    Write-Output "Renamer: $($config.plugins.dlsite_renamer.executable)"
    Write-Output "Audio: $($config.plugins.wav_to_mp3.script)"
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

if ($HideConsole) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeConsoleWindow {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    $consoleHandle = [NativeConsoleWindow]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [void][NativeConsoleWindow]::ShowWindow($consoleHandle, 0)
    }
}

$script:activeProcess = $null
$config = Read-AppConfig

$form = [Windows.Forms.Form]::new()
$form.Text = "自动解压处理工具 - 处理阶段"
$form.StartPosition = "CenterScreen"
$form.Size = [Drawing.Size]::new(900, 650)
$form.MinimumSize = [Drawing.Size]::new(760, 540)
$form.Font = [Drawing.Font]::new("Microsoft YaHei UI", 9)
$form.AllowDrop = $true

$topPanel = [Windows.Forms.Panel]::new()
$topPanel.Dock = "Top"
$topPanel.Height = 205
$topPanel.Padding = [Windows.Forms.Padding]::new(14)
$form.Controls.Add($topPanel)

$titleLabel = [Windows.Forms.Label]::new()
$titleLabel.Text = "处理阶段"
$titleLabel.Font = [Drawing.Font]::new("Microsoft YaHei UI", 17, [Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = [Drawing.Point]::new(14, 12)
$topPanel.Controls.Add($titleLabel)

$subtitleLabel = [Windows.Forms.Label]::new()
$subtitleLabel.Text = "DLsite 重命名 → WAV 转 MP3"
$subtitleLabel.ForeColor = [Drawing.Color]::DimGray
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = [Drawing.Point]::new(17, 48)
$topPanel.Controls.Add($subtitleLabel)

$pathLabel = [Windows.Forms.Label]::new()
$pathLabel.Text = "待处理目录（多个目录用分号分隔，也可直接多选拖入）"
$pathLabel.AutoSize = $true
$pathLabel.Location = [Drawing.Point]::new(15, 72)
$topPanel.Controls.Add($pathLabel)

$pathBox = [Windows.Forms.TextBox]::new()
$pathBox.Anchor = "Top,Left,Right"
$pathBox.Location = [Drawing.Point]::new(18, 96)
$pathBox.Size = [Drawing.Size]::new(747, 25)
$pathBox.AllowDrop = $true
$topPanel.Controls.Add($pathBox)

$browseButton = [Windows.Forms.Button]::new()
$browseButton.Text = "浏览…"
$browseButton.Anchor = "Top,Right"
$browseButton.Location = [Drawing.Point]::new(775, 94)
$browseButton.Size = [Drawing.Size]::new(90, 29)
$topPanel.Controls.Add($browseButton)

$planRadio = [Windows.Forms.RadioButton]::new()
$planRadio.Text = "预演（不修改文件）"
$planRadio.Checked = $true
$planRadio.AutoSize = $true
$planRadio.Location = [Drawing.Point]::new(18, 116)
$topPanel.Controls.Add($planRadio)

$runRadio = [Windows.Forms.RadioButton]::new()
$runRadio.Text = "实际执行"
$runRadio.AutoSize = $true
$runRadio.Location = [Drawing.Point]::new(190, 116)
$topPanel.Controls.Add($runRadio)

$skipRenamerBox = [Windows.Forms.CheckBox]::new()
$skipRenamerBox.Text = "跳过 DLsite 重命名，仅转换 WAV"
$skipRenamerBox.AutoSize = $true
$skipRenamerBox.Location = [Drawing.Point]::new(310, 116)
$topPanel.Controls.Add($skipRenamerBox)

$renamerStatus = [Windows.Forms.Label]::new()
$renamerStatus.AutoSize = $true
$renamerStatus.Location = [Drawing.Point]::new(18, 151)
$topPanel.Controls.Add($renamerStatus)

$audioStatus = [Windows.Forms.Label]::new()
$audioStatus.AutoSize = $true
$audioStatus.Location = [Drawing.Point]::new(18, 176)
$topPanel.Controls.Add($audioStatus)

$buttonPanel = [Windows.Forms.Panel]::new()
$buttonPanel.Dock = "Bottom"
$buttonPanel.Height = 58
$buttonPanel.Padding = [Windows.Forms.Padding]::new(14, 10, 14, 10)
$form.Controls.Add($buttonPanel)

$startButton = [Windows.Forms.Button]::new()
$startButton.Text = "开始"
$startButton.Size = [Drawing.Size]::new(110, 34)
$startButton.Location = [Drawing.Point]::new(14, 10)
$buttonPanel.Controls.Add($startButton)

$stopButton = [Windows.Forms.Button]::new()
$stopButton.Text = "停止"
$stopButton.Enabled = $false
$stopButton.Size = [Drawing.Size]::new(90, 34)
$stopButton.Location = [Drawing.Point]::new(134, 10)
$buttonPanel.Controls.Add($stopButton)

$clearButton = [Windows.Forms.Button]::new()
$clearButton.Text = "清空日志"
$clearButton.Size = [Drawing.Size]::new(90, 34)
$clearButton.Location = [Drawing.Point]::new(234, 10)
$buttonPanel.Controls.Add($clearButton)

$openProjectButton = [Windows.Forms.Button]::new()
$openProjectButton.Text = "打开项目目录"
$openProjectButton.Size = [Drawing.Size]::new(120, 34)
$openProjectButton.Location = [Drawing.Point]::new(334, 10)
$buttonPanel.Controls.Add($openProjectButton)

$stateLabel = [Windows.Forms.Label]::new()
$stateLabel.Text = "就绪"
$stateLabel.TextAlign = "MiddleRight"
$stateLabel.Anchor = "Top,Right"
$stateLabel.Location = [Drawing.Point]::new(700, 12)
$stateLabel.Size = [Drawing.Size]::new(165, 30)
$buttonPanel.Controls.Add($stateLabel)

$logBox = [Windows.Forms.RichTextBox]::new()
$logBox.Dock = "Fill"
$logBox.ReadOnly = $true
$logBox.BackColor = [Drawing.Color]::FromArgb(30, 30, 30)
$logBox.ForeColor = [Drawing.Color]::Gainsboro
$logBox.Font = [Drawing.Font]::new("Consolas", 10)
$logBox.WordWrap = $false
$logBox.DetectUrls = $false
$form.Controls.Add($logBox)
$logBox.BringToFront()

function Add-Log([string]$Text, [Drawing.Color]$Color = [Drawing.Color]::Gainsboro) {
    if ($form.IsDisposed) { return }
    $action = {
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.SelectionLength = 0
        $logBox.SelectionColor = $Color
        $logBox.AppendText($Text + [Environment]::NewLine)
        $logBox.SelectionColor = $logBox.ForeColor
        $logBox.ScrollToCaret()
    }
    if ($form.InvokeRequired) { [void]$form.BeginInvoke($action) } else { & $action }
}

function Set-RunningState([bool]$Running) {
    $action = {
        $startButton.Enabled = -not $Running
        $browseButton.Enabled = -not $Running
        $pathBox.Enabled = -not $Running
        $planRadio.Enabled = -not $Running
        $runRadio.Enabled = -not $Running
        $skipRenamerBox.Enabled = -not $Running
        $stopButton.Enabled = $Running
        $stateLabel.Text = if ($Running) { "处理中…" } else { "就绪" }
    }
    if ($form.InvokeRequired) { [void]$form.BeginInvoke($action) } else { & $action }
}

function Add-InputDirectories([string[]]$Paths) {
    $allPaths = [Collections.Generic.List[string]]::new()
    foreach ($existing in @($pathBox.Text -split '[;\r\n]+')) {
        $value = $existing.Trim()
        if ($value -and -not $allPaths.Contains($value)) { $allPaths.Add($value) }
    }
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            $resolved = (Resolve-Path -LiteralPath $path).Path
            if (-not $allPaths.Contains($resolved)) { $allPaths.Add($resolved) }
        }
    }
    $pathBox.Text = $allPaths -join '; '
}

$renamerExists = Test-Path -LiteralPath $config.plugins.dlsite_renamer.executable -PathType Leaf
$audioExists = Test-Path -LiteralPath $config.plugins.wav_to_mp3.script -PathType Leaf
$renamerStatus.Text = "DLsite 重命名插件：$(if ($renamerExists) { '已找到' } else { '未找到' })"
$renamerStatus.ForeColor = if ($renamerExists) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick }
$audioStatus.Text = "WAV 转 MP3 插件：$(if ($audioExists) { '已找到' } else { '未找到' })"
$audioStatus.ForeColor = if ($audioExists) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick }

$browseButton.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "选择已解压作品所在的父目录"
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        Add-InputDirectories @($dialog.SelectedPath)
    }
    $dialog.Dispose()
})

$dropHandler = {
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $items = @($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
        if ($items.Count -gt 0) { Add-InputDirectories $items }
    }
}
$dragEnterHandler = {
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
    }
}
$form.Add_DragEnter($dragEnterHandler)
$form.Add_DragDrop($dropHandler)
$pathBox.Add_DragEnter($dragEnterHandler)
$pathBox.Add_DragDrop($dropHandler)

$startButton.Add_Click({
    $inputDirectories = @($pathBox.Text -split '[;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $invalidDirectories = @($inputDirectories | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
    if ($inputDirectories.Count -eq 0 -or $invalidDirectories.Count -gt 0) {
        [Windows.Forms.MessageBox]::Show(
            $form,
            "请选择有效的待处理目录。",
            "输入无效",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    $logBox.Clear()
    Add-Log "启动处理阶段：$($inputDirectories.Count) 个目录" ([Drawing.Color]::LightSkyBlue)
    $inputDirectories | ForEach-Object { Add-Log "  $_" }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh.exe).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    [void]$startInfo.ArgumentList.Add("-NoProfile")
    [void]$startInfo.ArgumentList.Add("-ExecutionPolicy")
    [void]$startInfo.ArgumentList.Add("Bypass")
    [void]$startInfo.ArgumentList.Add("-File")
    [void]$startInfo.ArgumentList.Add($pipelineScript)
    foreach ($inputDirectory in $inputDirectories) {
        [void]$startInfo.ArgumentList.Add($inputDirectory)
    }
    if ($runRadio.Checked) { [void]$startInfo.ArgumentList.Add("-Run") }
    if ($skipRenamerBox.Checked) { [void]$startInfo.ArgumentList.Add("-SkipRenamer") }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $process.EnableRaisingEvents = $true
    $process.add_OutputDataReceived({
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) { Add-Log $eventArgs.Data }
    })
    $process.add_ErrorDataReceived({
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) { Add-Log $eventArgs.Data ([Drawing.Color]::LightCoral) }
    })
    $process.add_Exited({
        $exitCode = $process.ExitCode
        Add-Log "" 
        Add-Log "处理进程结束，退出代码：$exitCode" $(if ($exitCode -eq 0) { [Drawing.Color]::LightGreen } else { [Drawing.Color]::LightCoral })
        $script:activeProcess = $null
        Set-RunningState $false
        $process.Dispose()
    })

    try {
        if (-not $process.Start()) { throw "无法启动处理进程" }
        $script:activeProcess = $process
        Set-RunningState $true
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
    }
    catch {
        $script:activeProcess = $null
        Set-RunningState $false
        Add-Log "启动失败：$($_.Exception.Message)" ([Drawing.Color]::LightCoral)
        $process.Dispose()
    }
})

$stopButton.Add_Click({
    if ($script:activeProcess -and -not $script:activeProcess.HasExited) {
        try {
            $script:activeProcess.Kill($true)
            Add-Log "已请求停止处理进程。" ([Drawing.Color]::Khaki)
        }
        catch {
            Add-Log "停止失败：$($_.Exception.Message)" ([Drawing.Color]::LightCoral)
        }
    }
})

$clearButton.Add_Click({ $logBox.Clear() })
$openProjectButton.Add_Click({ Start-Process explorer.exe -ArgumentList $PSScriptRoot })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:activeProcess -and -not $script:activeProcess.HasExited) {
        $answer = [Windows.Forms.MessageBox]::Show(
            $form,
            "处理仍在运行。是否停止任务并关闭窗口？",
            "确认关闭",
            "YesNo",
            "Warning"
        )
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }
        try { $script:activeProcess.Kill($true) } catch {}
    }
})

Add-Log "请选择或拖入已解压作品所在的父目录。"
Add-Log "默认是预演模式，不会修改文件。" ([Drawing.Color]::Khaki)
[void]$form.ShowDialog()
