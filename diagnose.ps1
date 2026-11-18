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

# capture diagnose output: shown on screen AND saved to a report file ready to send
$repFile = Join-Path (Split-Path $found) 'report.txt'
$rep = & powershell -NoProfile -ExecutionPolicy Bypass -File $found -Diagnose 2>&1
$rep | ForEach-Object { $_.ToString() } | Write-Host
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$header = "MG Helper diagnostic report - $stamp - by Bayra & Kavel1n"
$header + "`r`n" + (($rep | ForEach-Object { $_.ToString() }) -join "`r`n") |
    Out-File (Join-Path (Split-Path $found) "report_$stamp.txt") -Encoding UTF8

Write-Host "=================================================="
Write-Host "[+] Report saved: report_$stamp.txt (in the watcher folder)" -ForegroundColor Green
Write-Host "    Send that FILE (not a screenshot) to Bayra / Kavel1n." -ForegroundColor Green
pause