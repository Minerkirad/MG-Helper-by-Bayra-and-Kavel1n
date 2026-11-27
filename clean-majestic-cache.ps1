# MG Helper - очистка кэша Majestic (по запросу). Universal discovery.
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
if (-not $cachePath -or -not (Test-Path -LiteralPath $cachePath)) {
    Write-Host '[!] Папка кэша Majestic не найдена.' -ForegroundColor Red
    Write-Host '    Проверь, что Majestic запускался хотя бы один раз.'
    exit 1
}

# --- target guards: never a drive root, Windows dir or a profile root ---
# Resolve-Path (not GetFullPath): real existing location, 8.3-names/symlinks expanded
$full = try { ((Resolve-Path -LiteralPath $cachePath -ErrorAction Stop).Path).TrimEnd('\') } catch {
    Write-Host '[!] Не удалось разрешить путь кэша - отменено.' -ForegroundColor Red
    exit 1
}
$badTargets = @(
    "$env:SystemDrive\",
    $env:SystemRoot,
    $env:USERPROFILE,
    $env:APPDATA,
    $env:LOCALAPPDATA,
    (Join-Path $env:USERPROFILE 'Documents'),
    (Join-Path $env:USERPROFILE 'Документы')
) | ForEach-Object { if ($_) { $_.TrimEnd('\') } }
if (($full -match '^[A-Za-z]:$') -or ($badTargets -contains $full)) {
    Write-Host "[!] Подозрительная цель очистки: $full - отменено." -ForegroundColor Red
    exit 1
}

# --- processes: never count powershell hosts or this process as the launcher ---
if (Get-Process -Name 'GTA5','GTA5_Enhanced' -ErrorAction SilentlyContinue) {
    Write-Host '[!] GTA5 запущена. Сначала выйди из игры!' -ForegroundColor Red
    exit 1
}
$majesticProc = Get-CimInstance Win32_Process -OperationTimeoutSec 15 -Filter "Name!='powershell.exe' AND Name!='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'majestic' -or ($_.ExecutablePath -and $_.ExecutablePath -match '\\majestic[^\\]*\.exe$') }
if ($majesticProc) {
    Write-Host '[!] Majestic запущен. Сначала закрой лаунчер!' -ForegroundColor Red
    exit 1
}

$size = (Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ''
Write-Host '============================================='
Write-Host ' Majestic cache cleaner - by Bayra & Kavel1n'
Write-Host '============================================='
Write-Host ''
Write-Host "Папка кэша: $full"
Write-Host ('Размер:     {0:N0} MB' -f $size)
Write-Host ''
Write-Host '[!] ВНИМАНИЕ: после очистки Majestic перекачает кэш при следующем запуске.' -ForegroundColor Yellow
Write-Host ''
if ($size -gt 10240) {
    $answer = Read-Host 'Объём больше 10 GB. Напиши слово "очистить" для подтверждения'
    if ($answer -ne 'очистить') { Write-Host 'Отменено.'; exit 0 }
} else {
    $answer = Read-Host 'Очистить кэш сейчас? (да/нет)'
    if ($answer -notmatch '^(д|да|y|yes)$') { Write-Host 'Отменено.'; exit 0 }
}

Get-ChildItem -LiteralPath $full -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Очищаю $($_.Name)..."
    Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue |
        ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
}
Get-ChildItem -LiteralPath $full -File -ErrorAction SilentlyContinue |
    ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {} }

$left = (Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ''
Write-Host ('[+] Готово. Осталось: {0:N0} MB' -f $left) -ForegroundColor Green
