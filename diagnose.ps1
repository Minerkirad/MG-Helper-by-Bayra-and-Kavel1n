# Locates the deployed watcher and runs its -Diagnose mode.
# Used as source for 5-diagnose.bat (EncodedCommand).
# by Bayra & Kavel1n
$host.UI.RawUI.WindowTitle = 'MG Helper Diagnose - by Bayra & Kavel1n'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$roots = @(
    "$env:LOCALAPPDATA\MG_Helper",
    "$env:USERPROFILE\Documents\Rockstar Games\GTA V\_settings_backup",
    "$env:USERPROFILE\OneDrive\Documents\Rockstar Games\GTA V\_settings_backup"
)
foreach ($one in (Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
    $roots += (Join-Path $one.FullName 'Documents\Rockstar Games\GTA V\_settings_backup')
}

$found = $null
foreach ($r in ($roots | Select-Object -Unique)) {
    $wp = Join-Path $r 'gta-settings-watcher.ps1'
    if (Test-Path $wp) { $found = $wp; break }
}

if (-not $found) {
    Write-Host "[!] Watcher not found on this PC." -ForegroundColor Red
    Write-Host "    Run 1-install.bat first (it installs the watcher)."
    Write-Host ""
    Write-Host "Searched:"
    $roots | ForEach-Object { Write-Host "    $_" }
    pause; exit 1
}

Write-Host "[i] Watcher found: $found"
Write-Host "=================================================="
& powershell -NoProfile -ExecutionPolicy Bypass -File $found -Diagnose
Write-Host "=================================================="
Write-Host "Send ALL of the output above to Bayra / Kavel1n."
pause