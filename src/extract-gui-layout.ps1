# Presentation only. Dot-sourced by extract-gui.ps1 after WinForms initialization.
$ui = @{
    Background = [Drawing.ColorTranslator]::FromHtml('#F4F6F8')
    Surface = [Drawing.Color]::White
    Text = [Drawing.ColorTranslator]::FromHtml('#202A35')
    Muted = [Drawing.ColorTranslator]::FromHtml('#637083')
    Border = [Drawing.ColorTranslator]::FromHtml('#DEE4EB')
    Accent = [Drawing.ColorTranslator]::FromHtml('#176B58')
    AccentSoft = [Drawing.ColorTranslator]::FromHtml('#E6F3ED')
    Warning = [Drawing.ColorTranslator]::FromHtml('#8B5810')
    WarningSoft = [Drawing.ColorTranslator]::FromHtml('#FFF3D9')
    Error = [Drawing.ColorTranslator]::FromHtml('#B43D3D')
    Log = [Drawing.ColorTranslator]::FromHtml('#17212D')
}

function New-UiLabel([string]$Text, [int]$Size = 9) {
    $control = [Windows.Forms.Label]::new()
    $control.Text = $Text
    $control.Font = [Drawing.Font]::new('Microsoft YaHei UI', $Size)
    $control.ForeColor = $ui.Text
    $control.AutoSize = $false
    $control.Dock = 'Fill'
    $control.TextAlign = 'MiddleLeft'
    $control.Margin = [Windows.Forms.Padding]::new(0)
    return $control
}

function New-UiButton([string]$Text, [int]$Width = 98, [bool]$Primary = $false) {
    $control = [Windows.Forms.Button]::new()
    $control.Text = $Text
    $control.Size = [Drawing.Size]::new($Width, 32)
    $control.Margin = [Windows.Forms.Padding]::new(0, 0, 8, 0)
    $control.FlatStyle = 'Flat'
    $control.FlatAppearance.BorderSize = 1
    $control.FlatAppearance.BorderColor = $ui.Border
    $control.BackColor = $ui.Surface
    $control.ForeColor = $ui.Text
    $control.Cursor = [Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $control.BackColor = $ui.Accent
        $control.ForeColor = [Drawing.Color]::White
        $control.FlatAppearance.BorderColor = $ui.Accent
    }
    return $control
}

function New-UiTable([int]$Columns, [int]$Rows) {
    $control = [Windows.Forms.TableLayoutPanel]::new()
    $control.ColumnCount = $Columns
    $control.RowCount = $Rows
    $control.Dock = 'Fill'
    $control.Margin = [Windows.Forms.Padding]::new(0)
    return $control
}

$form = [Windows.Forms.Form]::new()
$form.Text = '自动解压处理工具 · 工作台'
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = [Drawing.Size]::new(1040, 690)
$form.MinimumSize = [Drawing.Size]::new(900, 650)
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 9)
$form.BackColor = $ui.Background
$form.ForeColor = $ui.Text
$form.AllowDrop = $true
$form.Padding = [Windows.Forms.Padding]::new(18, 10, 18, 12)

$layout = New-UiTable 1 6
[void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
foreach ($height in @(58, 70, 72)) { [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', $height)) }
[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 32))
[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 72))
$form.Controls.Add($layout)

$header = New-UiTable 2 2
[void]$header.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
[void]$header.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 120))
[void]$header.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 32))
[void]$header.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$title = New-UiLabel '自动解压 + 文件处理' 16
$title.Font = [Drawing.Font]::new('Microsoft YaHei UI', 16, [Drawing.FontStyle]::Bold)
$hint = New-UiLabel '拖入文件或文件夹，一次完成解压、音频处理与作品命名'
$hint.ForeColor = $ui.Muted
$rulesButton = New-UiButton '查看处理规则' 120
$rulesButton.Anchor = 'Top,Right'
$header.Controls.Add($title, 0, 0)
$header.Controls.Add($hint, 0, 1)
$header.Controls.Add($rulesButton, 1, 0)
$layout.Controls.Add($header, 0, 0)

$destination = New-UiTable 3 2
$destination.Padding = [Windows.Forms.Padding]::new(0, 2, 0, 8)
[void]$destination.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 74))
[void]$destination.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
[void]$destination.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 106))
[void]$destination.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 28))
[void]$destination.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$destination.Controls.Add((New-UiLabel '输出位置'), 0, 0)
$outputModes = [Windows.Forms.FlowLayoutPanel]::new()
$outputModes.Dock = 'Fill'
$outputModes.Margin = [Windows.Forms.Padding]::new(0)
$outputModes.WrapContents = $false
$customRadio = [Windows.Forms.RadioButton]::new()
$customRadio.Text = '指定文件夹'
$customRadio.Checked = $true
$customRadio.AutoSize = $true
$customRadio.Margin = [Windows.Forms.Padding]::new(0, 3, 20, 0)
$sourceRadio = [Windows.Forms.RadioButton]::new()
$sourceRadio.Text = '原压缩包旁'
$sourceRadio.AutoSize = $true
$sourceRadio.Margin = [Windows.Forms.Padding]::new(0, 3, 0, 0)
$outputModes.Controls.AddRange(@($customRadio, $sourceRadio))
$destination.Controls.Add($outputModes, 1, 0)
$openOutput = New-UiButton '打开输出' 98
$openOutput.Height = 26
$openOutput.Anchor = 'Right'
$destination.Controls.Add($openOutput, 2, 0)
$outputBox = [Windows.Forms.TextBox]::new()
$outputBox.Dock = 'Fill'
$outputBox.Margin = [Windows.Forms.Padding]::new(0, 2, 8, 0)
$outputBox.PlaceholderText = '选择处理结果的保存位置'
$destination.Controls.Add($outputBox, 0, 1)
$destination.SetColumnSpan($outputBox, 2)
$outputBrowse = New-UiButton '选择位置…' 98
$outputBrowse.Height = 28
$outputBrowse.Anchor = 'Top,Right'
$outputBrowse.Margin = [Windows.Forms.Padding]::new(0, 0, 0, 0)
$destination.Controls.Add($outputBrowse, 2, 1)
$layout.Controls.Add($destination, 0, 1)

$stages = New-UiTable 3 1
[void]$stages.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$stages.Padding = [Windows.Forms.Padding]::new(0, 2, 0, 10)
$stageLabels = @()
foreach ($name in @('递归解压', '文件处理', '作品命名')) {
    [void]$stages.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 33.3333))
    $label = New-UiLabel ''
    $label.BackColor = $ui.Surface
    $label.Padding = [Windows.Forms.Padding]::new(14, 0, 0, 0)
    $label.Margin = [Windows.Forms.Padding]::new(0, 0, $(if ($stageLabels.Count -lt 2) { 8 } else { 0 }), 0)
    $stages.Controls.Add($label, $stageLabels.Count, 0)
    $stageLabels += $label
}
$layout.Controls.Add($stages, 0, 2)

$workspace = [Windows.Forms.SplitContainer]::new()
$workspace.Dock = 'Fill'
$workspace.Margin = [Windows.Forms.Padding]::new(0)
$workspace.Size = [Drawing.Size]::new(1000, 370)
$workspace.SplitterDistance = 320
$workspace.SplitterWidth = 12
$workspace.Panel1MinSize = 280
$workspace.Panel2MinSize = 400
$workspace.FixedPanel = 'Panel1'
$layout.Controls.Add($workspace, 0, 3)

$inputsPanel = New-UiTable 1 5
$inputsPanel.BackColor = $ui.Surface
$inputsPanel.Padding = [Windows.Forms.Padding]::new(12)
foreach ($height in @(28, 38)) { [void]$inputsPanel.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', $height)) }
[void]$inputsPanel.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
[void]$inputsPanel.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 32))
[void]$inputsPanel.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 38))
$inputCount = New-UiLabel '待处理输入 · 0 项'
$inputsPanel.Controls.Add($inputCount, 0, 0)
$inputActions = [Windows.Forms.FlowLayoutPanel]::new()
$inputActions.Dock = 'Fill'
$inputActions.WrapContents = $false
$inputActions.Margin = [Windows.Forms.Padding]::new(0)
$addFolder = New-UiButton '添加文件夹' 118
$addFiles = New-UiButton '添加压缩包' 118
$inputActions.Controls.AddRange(@($addFolder, $addFiles))
$inputsPanel.Controls.Add($inputActions, 0, 1)
$inputHost = [Windows.Forms.Panel]::new()
$inputHost.Dock = 'Fill'
$inputHost.Margin = [Windows.Forms.Padding]::new(0)
$inputList = [Windows.Forms.ListBox]::new()
$inputList.Dock = 'Fill'
$inputList.BorderStyle = 'None'
$inputList.IntegralHeight = $false
$inputList.SelectionMode = 'MultiExtended'
$inputList.DrawMode = 'OwnerDrawFixed'
$inputList.ItemHeight = 52
$inputList.BackColor = $ui.Surface
$inputList.ForeColor = $ui.Text
$inputList.AccessibleName = '待处理文件和文件夹'
$inputHost.Controls.Add($inputList)
$emptyInput = New-UiLabel "拖入压缩包或文件夹`r`n`r`n支持多选、分卷与递归解压"
$emptyInput.TextAlign = 'MiddleCenter'
$emptyInput.ForeColor = $ui.Muted
$emptyInput.BackColor = $ui.Surface
$inputHost.Controls.Add($emptyInput)
$emptyInput.BringToFront()
$inputsPanel.Controls.Add($inputHost, 0, 2)
$selectionHint = New-UiLabel '可拖入多个文件，分卷会按作品分组'
$selectionHint.ForeColor = $ui.Muted
$selectionHint.AutoEllipsis = $true
$inputsPanel.Controls.Add($selectionHint, 0, 3)
$removeActions = [Windows.Forms.FlowLayoutPanel]::new()
$removeActions.Dock = 'Fill'
$removeActions.WrapContents = $false
$removeActions.Margin = [Windows.Forms.Padding]::new(0, 4, 0, 0)
$removeInput = New-UiButton '移除选中' 118
$clearInputs = New-UiButton '清空列表' 118
$removeActions.Controls.AddRange(@($removeInput, $clearInputs))
$inputsPanel.Controls.Add($removeActions, 0, 4)
$workspace.Panel1.Controls.Add($inputsPanel)

$logPanel = New-UiTable 1 2
$logPanel.BackColor = $ui.Log
$logPanel.Padding = [Windows.Forms.Padding]::new(12, 8, 12, 8)
[void]$logPanel.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 38))
[void]$logPanel.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$logHeader = New-UiTable 2 1
[void]$logHeader.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
[void]$logHeader.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
[void]$logHeader.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 94))
$logTitle = New-UiLabel '运行日志'
$logTitle.ForeColor = [Drawing.Color]::WhiteSmoke
$clearLog = New-UiButton '清空显示' 88
$clearLog.BackColor = $ui.Log
$clearLog.ForeColor = [Drawing.Color]::Gainsboro
$clearLog.FlatAppearance.BorderColor = [Drawing.ColorTranslator]::FromHtml('#425065')
$logHeader.Controls.Add($logTitle, 0, 0)
$logHeader.Controls.Add($clearLog, 1, 0)
$logPanel.Controls.Add($logHeader, 0, 0)
$log = [Windows.Forms.RichTextBox]::new()
$log.Dock = 'Fill'
$log.ReadOnly = $true
$log.BorderStyle = 'None'
$log.BackColor = $ui.Log
$log.ForeColor = [Drawing.Color]::Gainsboro
$log.Font = [Drawing.Font]::new('Microsoft YaHei UI', 9)
$log.WordWrap = $true
$log.DetectUrls = $false
$log.AccessibleName = '实时运行日志'
$logPanel.Controls.Add($log, 0, 1)
$workspace.Panel2.Controls.Add($logPanel)

$policySummary = New-UiLabel '处理规则加载中…'
$policySummary.ForeColor = $ui.Muted
$policySummary.AutoEllipsis = $true
$layout.Controls.Add($policySummary, 0, 4)

$bottom = New-UiTable 3 2
[void]$bottom.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
[void]$bottom.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 144))
[void]$bottom.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 222))
[void]$bottom.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 42))
[void]$bottom.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
$status = New-UiLabel '就绪 · 添加输入后开始处理'
$status.AutoEllipsis = $true
$elapsedLabel = New-UiLabel '耗时 00:00:00'
$elapsedLabel.TextAlign = 'MiddleRight'
$elapsedLabel.ForeColor = $ui.Muted
$runActions = [Windows.Forms.FlowLayoutPanel]::new()
$runActions.Dock = 'Fill'
$runActions.FlowDirection = 'RightToLeft'
$runActions.WrapContents = $false
$runActions.Margin = [Windows.Forms.Padding]::new(0, 4, 0, 0)
$start = New-UiButton '开始处理' 118 $true
$start.Margin = [Windows.Forms.Padding]::new(0)
$stop = New-UiButton '停止' 80
$stop.Enabled = $false
$runActions.Controls.AddRange(@($start, $stop))
$bottom.Controls.Add($status, 0, 0)
$bottom.Controls.Add($elapsedLabel, 1, 0)
$bottom.Controls.Add($runActions, 2, 0)
$progressArea = New-UiTable 2 1
[void]$progressArea.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
[void]$progressArea.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 244))
[void]$progressArea.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
$progressLabel = New-UiLabel '等待开始'
$progressLabel.ForeColor = $ui.Muted
$overallProgress = [Windows.Forms.ProgressBar]::new()
$overallProgress.Dock = 'Fill'
$overallProgress.Margin = [Windows.Forms.Padding]::new(0, 8, 0, 4)
$overallProgress.Minimum = 0
$overallProgress.Maximum = 1
$overallProgress.Value = 0
$overallProgress.MarqueeAnimationSpeed = 25
$progressArea.Controls.Add($progressLabel, 0, 0)
$progressArea.Controls.Add($overallProgress, 1, 0)
$bottom.Controls.Add($progressArea, 0, 1)
$bottom.SetColumnSpan($progressArea, 3)
$layout.Controls.Add($bottom, 0, 5)

$toolTip = [Windows.Forms.ToolTip]::new()
$toolTip.SetToolTip($clearLog, '仅清空窗口中的日志，磁盘日志不受影响')
$toolTip.SetToolTip($stop, '立即停止本次处理进程及其子进程')
$toolTip.SetToolTip($openOutput, '指定位置模式打开输出目录；原地址模式打开选中输入所在目录')
$toolTip.SetToolTip($clearInputs, '仅移除待处理列表中的路径，不删除文件')
$inputList.Add_DrawItem({
    param($sender, $eventArgs)
    if ($eventArgs.Index -lt 0) { return }
    $path = [string]$sender.Items[$eventArgs.Index]
    $selected = ($eventArgs.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $back = if ($selected) { $ui.AccentSoft } else { $ui.Surface }
    $brush = [Drawing.SolidBrush]::new($back)
    try { $eventArgs.Graphics.FillRectangle($brush, $eventArgs.Bounds) } finally { $brush.Dispose() }
    $factor = $sender.DeviceDpi / 96.0
    $nameBounds = [Drawing.Rectangle]::new($eventArgs.Bounds.X + [int](8*$factor), $eventArgs.Bounds.Y + [int](5*$factor), $eventArgs.Bounds.Width - [int](16*$factor), [int](22*$factor))
    $parentBounds = [Drawing.Rectangle]::new($nameBounds.X, $eventArgs.Bounds.Y + [int](28*$factor), $nameBounds.Width, [int](20*$factor))
    $flags = [Windows.Forms.TextFormatFlags]::EndEllipsis -bor [Windows.Forms.TextFormatFlags]::NoPrefix -bor [Windows.Forms.TextFormatFlags]::SingleLine
    $name = [IO.Path]::GetFileName($path.TrimEnd('\'))
    if (-not $name) { $name = $path }
    [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $name, $sender.Font, $nameBounds, $ui.Text, $flags)
    [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, [IO.Path]::GetDirectoryName($path), $sender.Font, $parentBounds, $ui.Muted, $flags)
    $eventArgs.DrawFocusRectangle()
})
$inputList.Add_SelectedIndexChanged({
    $selectionHint.Text = if ($inputList.SelectedItems.Count -gt 0) { [string]$inputList.SelectedItems[0] } else { '可拖入多个文件，分卷会按作品分组' }
    $toolTip.SetToolTip($selectionHint, $selectionHint.Text)
})
$form.Add_Shown({ $inputList.ItemHeight = [int](52 * $form.DeviceDpi / 96.0) })
$form.Add_DpiChanged({ $inputList.ItemHeight = [int](52 * $form.DeviceDpi / 96.0) })

function Update-InputSummary {
    $inputCount.Text = "待处理输入 · $($inputList.Items.Count) 项"
    $emptyInput.Visible = ($inputList.Items.Count -eq 0)
    $inputList.Visible = ($inputList.Items.Count -gt 0)
    if ($inputList.SelectedItems.Count -eq 0) {
        $selectionHint.Text = '可拖入多个文件，分卷会按作品分组'
        $toolTip.SetToolTip($selectionHint, $selectionHint.Text)
    }
}

function Show-ProcessingRules {
    try {
        $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.json') -Raw -Encoding utf8 | ConvertFrom-Json
        $archiveRule = if ($config.extraction.keep_original_archives) { '保留原压缩包' } else { '整组解压并提交成功后删除原包；失败保留原包与现场' }
        $audioRule = if ($config.processing.wav_after_success -eq 'delete') { '匹配或转换为有效 MP3 后删除对应 WAV / FLAC；失败保留源文件' } else { '按当前配置保留源音频' }
        $videoRule = if ($config.processing.delete_mp4) { '删除作品目录中的 MP4 文件' } else { '保留 MP4 文件' }
        $namingRule = if ($config.naming.enabled) { '自动补全作品名称；查不到名称时保留目录并记录待补全' } else { '未启用作品名称补全' }
        $script:ruleText = "递归解压`r`n$archiveRule`r`n`r`n音频处理`r`n$audioRule`r`n`r`n视频处理`r`n$videoRule`r`n`r`n作品命名`r`n$namingRule"
        $shortArchive = if ($config.extraction.keep_original_archives) { '保留原包' } else { '解压成功后删原包' }
        $shortAudio = if ($config.processing.wav_after_success -eq 'delete') { 'MP3 校验后删源音频' } else { '保留源音频' }
        $shortVideo = if ($config.processing.delete_mp4) { '删除 MP4' } else { '保留 MP4' }
        $policySummary.Text = "当前规则  ·  $shortArchive  /  $shortAudio  /  $shortVideo"
        $toolTip.SetToolTip($policySummary, $script:ruleText)
    } catch {
        $policySummary.Text = '未能读取处理规则，请检查 config.json'
        $script:ruleText = "无法读取当前处理规则：$($_.Exception.Message)"
    }
}
$rulesButton.Add_Click({
    Show-ProcessingRules
    [void][Windows.Forms.MessageBox]::Show($form, $script:ruleText, '当前处理规则', 'OK', 'Information')
})
$openOutput.Add_Click({
    $target = $outputBox.Text.Trim()
    if ($sourceRadio.Checked) {
        $selected = if ($inputList.SelectedItems.Count -gt 0) { [string]$inputList.SelectedItems[0] } elseif ($inputList.Items.Count -eq 1) { [string]$inputList.Items[0] } else { '' }
        if (-not $selected) {
            [void][Windows.Forms.MessageBox]::Show($form, '请先选中一个输入，打开它所在的目录。', '选择输入', 'OK', 'Information')
            return
        }
        $target = if (Test-Path -LiteralPath $selected -PathType Container) { $selected } else { [IO.Path]::GetDirectoryName($selected) }
    }
    if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Container)) {
        [void][Windows.Forms.MessageBox]::Show($form, '输出目录尚未设置或已经不存在。', '无法打开输出', 'OK', 'Information')
        return
    }
    try {
        $openInfo = [Diagnostics.ProcessStartInfo]::new()
        $openInfo.FileName = $target
        $openInfo.UseShellExecute = $true
        [void][Diagnostics.Process]::Start($openInfo)
    } catch { Add-Log "打开输出目录失败：$($_.Exception.Message)" ([Drawing.Color]::LightCoral) }
})
Show-ProcessingRules
Update-InputSummary
