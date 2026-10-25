function Find-Bandizip([string]$ConfiguredPath) {
    if ($ConfiguredPath) {
        if (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf) { return $ConfiguredPath }
        throw "找不到配置的 Bandizip：$ConfiguredPath"
    }
    foreach ($candidate in @('C:\Program Files\Bandizip\bz.exe', 'C:\Program Files (x86)\Bandizip\bz.exe')) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command bz.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw '未找到 Bandizip 命令行程序 bz.exe，请安装官方 Bandizip。'
}

function Invoke-BandizipExtraction([string]$Executable, [string]$Archive, [string]$Destination, $Password, [int]$CodePage = 932) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($arg in @('x', '-y', '-aoa', '-consolemode:utf8', "-o:$Destination")) { $info.ArgumentList.Add($arg) }
    if ($CodePage -gt 0) { $info.ArgumentList.Add("-cp:$CodePage") }
    if ($null -ne $Password) { $info.ArgumentList.Add("-p:$Password") }
    $info.ArgumentList.Add('-')
    $info.ArgumentList.Add($Archive)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        # EOF prevents password prompts from blocking an unattended worker.
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [PSCustomObject]@{ ExitCode=$process.ExitCode; Output=@($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult()) }
    } finally { $process.Dispose() }
}
