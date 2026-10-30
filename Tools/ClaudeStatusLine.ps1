param([string]$CachePath, [string]$CollectorPath)

# Claude supplies JSON on stdin. Pass it through memory only; never record raw input or stderr.
$ErrorActionPreference = 'Stop'
try {
    $collector = if ([string]::IsNullOrWhiteSpace($CollectorPath) -eq $true) {
        $packagedCollector = Join-Path $PSScriptRoot '..\UsageViewer.exe'
        if (Test-Path -LiteralPath $packagedCollector) {
            $packagedCollector
        } else {
            Join-Path $PSScriptRoot '..\src\UsageViewer\bin\Release\net10.0-windows\UsageViewer.exe'
        }
    } else { $CollectorPath }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new([IO.Path]::GetFullPath($collector))
    $startInfo.ArgumentList.Add('--claude-statusline')
    if ([string]::IsNullOrWhiteSpace($CachePath) -eq $false) {
        $startInfo.ArgumentList.Add($CachePath)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $payload = $input | Out-String
    $process.StandardInput.Write($payload)
    $process.StandardInput.Close()
    if ($process.WaitForExit(5000) -eq $false) {
        $process.Kill($true)
        $process.WaitForExit()
        exit 1
    }
    if ($process.ExitCode -eq 0) {
        [Console]::Write($outputTask.GetAwaiter().GetResult())
    }
    exit $process.ExitCode
} catch {
    exit 1
} finally {
    if ($null -ne $process) {
        $process.Dispose()
    }
}
