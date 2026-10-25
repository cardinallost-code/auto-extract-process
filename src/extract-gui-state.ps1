# UI state derives only from pipeline messages and its final exit code.
$script:currentStage = 0
$script:stageStates = @('等待', '等待', '等待')
$script:extractionHasFailures = $false
$script:namingHasFailures = $false

function Update-StageLabels {
    $names = @('递归解压', '文件处理', '作品命名')
    $descriptions = @('分卷识别与递归展开', 'WAV / FLAC → MP3', '补全作品标题与声优')
    for ($index = 0; $index -lt 3; $index++) {
        $label = $stageLabels[$index]
        $state = $script:stageStates[$index]
        $label.Text = "$($index + 1)  $($names[$index])  ·  $state`r`n$($descriptions[$index])"
        $label.BackColor = $ui.Surface
        $label.ForeColor = $ui.Muted
        if ($state -eq '进行中' -or $state -eq '完成') {
            $label.BackColor = $ui.AccentSoft
            $label.ForeColor = $ui.Accent
        } elseif ($state -in @('部分失败', '未完成', '待补全', '已停止')) {
            $label.BackColor = $ui.WarningSoft
            $label.ForeColor = $ui.Warning
        }
    }
}

function Reset-RunDisplay {
    $script:currentStage = 0
    $script:stageStates = @('等待', '等待', '等待')
    $script:extractionHasFailures = $false
    $script:namingHasFailures = $false
    $overallProgress.Style = 'Continuous'
    $overallProgress.Value = 0
    $status.ForeColor = $ui.Text
    Update-StageLabels
}

function Set-CurrentStage([int]$Stage) {
    if ($Stage -lt 1 -or $Stage -gt 3) { return }
    if ($script:currentStage -gt 0 -and $Stage -gt $script:currentStage) {
        $script:stageStates[$script:currentStage - 1] = '完成'
    }
    $script:currentStage = $Stage
    $script:stageStates[$Stage - 1] = '进行中'
    if ($script:extractionHasFailures -and $Stage -gt 1) { $script:stageStates[0] = '部分失败' }
    $names = @('递归解压', '文件处理', '作品命名')
    $status.Text = "正在$($names[$Stage - 1]) · 阶段 $Stage/3"
    if ($Stage -eq 1) {
        $overallProgress.Style = 'Continuous'
        $progressLabel.Text = "解压分组 0/$($script:projectTotal) 已结束"
    } else {
        # The pipeline has no reliable total for audio or naming; never invent a percentage.
        $overallProgress.Style = 'Marquee'
        $progressLabel.Text = "$($names[$Stage - 1])进行中"
    }
    Update-StageLabels
}

function Complete-RunDisplay([int]$ExitCode, [bool]$Stopped) {
    $overallProgress.Style = 'Continuous'
    $overallProgress.Value = 0
    if ($Stopped) {
        if ($script:currentStage -gt 0) { $script:stageStates[$script:currentStage - 1] = '已停止' }
        $status.Text = '已停止 · 本次日志已保留'
        $status.ForeColor = $ui.Warning
        $progressLabel.Text = '任务已停止'
    } elseif ($ExitCode -eq 0) {
        $script:stageStates = @('完成', '完成', '完成')
        $overallProgress.Value = $overallProgress.Maximum
        $status.Text = '全部完成 · 可打开输出目录'
        $status.ForeColor = $ui.Accent
        $progressLabel.Text = '三个阶段全部完成'
    } else {
        if ($script:currentStage -gt 0) {
            $script:stageStates[$script:currentStage - 1] = '未完成'
        }
        if ($script:extractionHasFailures) { $script:stageStates[0] = '部分失败' }
        if ($script:namingHasFailures) { $script:stageStates[2] = '待补全' }
        if ($script:currentStage -eq 3 -and $script:extractionHasFailures -and -not $script:namingHasFailures) {
            $script:stageStates[2] = '完成'
        }
        $status.Text = if ($script:namingHasFailures -and -not $script:extractionHasFailures) { '名称待补全 · 已保留处理结果' } else { "存在未完成项 · 退出代码 $ExitCode" }
        $status.ForeColor = $ui.Error
        $progressLabel.Text = '请查看日志中的失败原因'
    }
    Update-StageLabels
}
Update-StageLabels
