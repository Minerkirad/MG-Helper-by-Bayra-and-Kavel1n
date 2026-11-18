# Cleans the whole Majestic asset cache (on demand). Universal discovery.
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Clean Cache'

$cachePath = $null
$cfgPath = Join-Path $env:LOCALAPPDATA 'MG_Helper\config.json'
$mjJson  = Join-Path $env:APPDATA 'majestic-launcher\Multiplayer\majestic.json'
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($cfg.majesticJson -and (Test-Path -LiteralPath $cfg.majesticJson)) { $mjJson = $cfg.majesticJson }
    } catch {}
}
if (Test-Path $mjJson) {
    try {
        $j = Get-Content $mjJson -Raw | ConvertFrom-Json
        foreach ($k in @('cachePath','cache','CachePath','cache_path')) {
            if ($j.$k) { $cachePath = ($j.$k -replace '"',''); break }
        }
    } catch {}
}
if (-not $cachePath -or -not (Test-Path $cachePath)) {
    Write-Host "[!] Majestic cache folder not found." -ForegroundColor Red
    Write-Host "    Check that Majestic was started at least once."
    pause; exit 1
}

if (Get-Process GTA5 -ErrorAction SilentlyContinue) {
    Write-Host "[!] GTA5 is running. Close it first!" -ForegroundColor Red
    pause; exit 1
}
$majesticProc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'majestic' }
if ($majesticProc) {
    Write-Host "[!] Majestic is running. Close it first!" -ForegroundColor Red
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