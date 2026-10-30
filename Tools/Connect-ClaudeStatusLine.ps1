param([string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'))

$ErrorActionPreference = 'Stop'
$runner = (Get-Command pwsh -ErrorAction Stop).Source.Replace('\', '/')
$scriptPath = (Join-Path $PSScriptRoot 'ClaudeStatusLine.ps1').Replace('\', '/')
$legacyCommand = '"' + $runner + '" -NoProfile -NonInteractive -File "' + $scriptPath + '"'
# A quoted executable path alone is not an invocation in PowerShell. A command name works in both shells.
$command = 'pwsh -NoProfile -NonInteractive -File "' + $scriptPath + '"'
$content = if (Test-Path -LiteralPath $SettingsPath) { [IO.File]::ReadAllText($SettingsPath) } else { '{}' }
$settings = ConvertFrom-Json -InputObject $content -AsHashtable
if ($null -eq $settings) { throw 'Claude settings must contain a JSON object.' }
if ($settings.ContainsKey('statusLine') -eq $true -and $null -ne $settings.statusLine) {
    if ($settings.statusLine.type -eq 'command' -and $settings.statusLine.command -eq $command) {
        Write-Output 'Claude statusLine is already connected.'
        exit 0
    }
    if ($settings.statusLine.type -ne 'command' -or $settings.statusLine.command -ne $legacyCommand) {
        throw 'An existing Claude statusLine was found and preserved. No settings were changed.'
    }
}

$settings.statusLine = @{ type = 'command'; command = $command }
# Recheck before replacing to avoid overwriting a concurrent settings edit.
$latest = if (Test-Path -LiteralPath $SettingsPath) { [IO.File]::ReadAllText($SettingsPath) } else { '{}' }
if ($latest -ne $content) { throw 'Claude settings changed during setup. No settings were changed.' }
$directory = Split-Path -Parent ([IO.Path]::GetFullPath($SettingsPath))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$temporaryPath = Join-Path $directory ('usageviewer-settings-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json -InputObject $settings -Depth 100), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryPath, [IO.Path]::GetFullPath($SettingsPath), $true)
} finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath }
}
Write-Output 'Claude statusLine connected. Other settings were preserved.'
