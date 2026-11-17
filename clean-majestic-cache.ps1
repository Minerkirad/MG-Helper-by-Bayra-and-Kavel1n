# Cleans the whole Majestic asset cache (on demand).
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'Majestic Cache Cleaner - by Bayra & Kavel1n'

$cachePath = $null
$mjJson = "$env:APPDATA\majestic-launcher\Multiplayer\majestic.json"
if (Test-Path $mjJson) {
    try { $cachePath = (Get-Content $mjJson -Raw | ConvertFrom-Json).cachePath } catch {}
}
if (-not $cachePath -or -not (Test-Path $cachePath)) {
    Write-Host "[!] Majestic cache folder not found." -ForegroundColor Red
    pause; exit 1
}

if (Get-Process GTA5, 'Majestic Launcher' -ErrorAction SilentlyContinue) {
    Write-Host "[!] Majestic or GTA5 is running. Close them first!" -ForegroundColor Red
    pause; exit 1
}

$size = (Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Write-Host "============================================="
Write-Host " Majestic cache cleaner - by Bayra & Kavel1n"
Write-Host "============================================="
Write-Host ""
Write-Host ("Cache folder: $cachePath")
Write-Host ("Cache size:   {0:N0} MB" -f $size)
Write-Host ""
Write-Host "[!] WARNING: after cleaning, Majestic will re-download the whole cache on next launch." -ForegroundColor Yellow
Write-Host ""
$answer = Read-Host "Clean the cache now? (y/n)"
if ($answer -notin 'y','Y') { Write-Host "Cancelled."; pause; exit 0 }

Get-ChildItem $cachePath -Directory | ForEach-Object {
    Write-Host "Cleaning $($_.Name)..."
    Remove-Item "$($_.FullName)\*" -Recurse -Force -ErrorAction SilentlyContinue
}

$left = (Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Write-Host ("[+] Done. Remaining: {0:N0} MB" -f $left) -ForegroundColor Green
pause