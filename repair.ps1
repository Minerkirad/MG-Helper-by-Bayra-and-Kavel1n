# MG Helper repair - fixes typical problems on demand.
# Re-runs the installer (single source of truth for scripts/config/watcher),
# heals golden, clears read-only, restarts the watcher.
# Optional: vanilla .bin restore with confirmation.
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Repair'
$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
. (Join-Path $root 'common.ps1')

$results = @()

Write-Host "============================================="
Write-Host " MG Helper repair - by Bayra & Kavel1n"
Write-Host "============================================="
Write-Host ""

# --- 0. settings.xml location (re-discover) ---
$cfg0 = Resolve-MgPaths -ForceFull
if ($cfg0.settingsXml) { $results += @{ ok = $true;  msg = "Пути переопределены: settings.xml найден" } }
else {                  $results += @{ ok = $false; msg = "settings.xml НЕ найден на этом ПК - запусти GTA V один раз" } }

# --- 1. golden self-heal chain (BEFORE installer, so the installer migrates the healed golden) ---
$Golden = Join-Path $HelperDir 'settings.golden.xml'
$gSrc = $null
$chain = @($Golden, "$Golden.bak", (Join-Path $HelperDir 'settings.before_apply.bak'), $cfg0.settingsXml) |
    Where-Object { $_ } | Select-Object -Unique
foreach ($c in $chain) {
    try {
        $raw = Get-Content -LiteralPath $c -Raw -ErrorAction Stop
        if ($raw.Length -gt 100 -and $raw -match '<Settings>' -and ($raw -notmatch '\$\d')) { $gSrc = $c; break }
    } catch {}
}
if ($gSrc -and ($gSrc -ne $Golden)) {
    New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
    Copy-Item $gSrc $Golden -Force
    $results += @{ ok = $true;  msg = "Эталон восстановлен из $((Split-Path $gSrc -Leaf))" }
}
elseif ($gSrc) { $results += @{ ok = $true;  msg = "Эталон валиден - восстановление не потребовалось" } }
else {              $results += @{ ok = $false; msg = "Ни одного валидного источника эталона не найдено" } }

# --- 2. read-only attribute on settings.xml ---
if ($cfg0.settingsXml -and (Test-Path -LiteralPath $cfg0.settingsXml)) {
    $item = Get-Item -LiteralPath $cfg0.settingsXml
    if ($item.IsReadOnly) {
        Set-ItemProperty -LiteralPath $cfg0.settingsXml -Name IsReadOnly -Value $false
        $results += @{ ok = $true;  msg = "Атрибут 'только чтение' снят с settings.xml" }
    } else { $results += @{ ok = $true;  msg = "settings.xml доступен для записи" } }
}

# --- 3. re-run installer (deploys watcher + common + config + autostart + watchdog) ---
$installer = Join-Path $root 'install-gta-watcher.ps1'
if (-not (Test-Path -LiteralPath $installer)) {
    Write-Host "[!] install-gta-watcher.ps1 не найден в папке пакета - переустанови пакет целиком." -ForegroundColor Red
    pause; exit 1
}
'' | powershell -NoProfile -ExecutionPolicy Bypass -File $installer 2>&1 | ForEach-Object { Write-Host "  $_" }

# --- 4. verify watcher process is alive after installer restart ---
Start-Sleep 4
# precise pattern + exclude ourselves: 'MG_Helper' matched ANY script running
# from the helper dir (incl. this repair), producing a fake "watcher is alive"
$alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { ($_.ProcessId -ne $PID) -and ($_.CommandLine -match 'gta-settings-watcher\.ps1') })
if ($alive.Count -gt 0) { $results += @{ ok = $true;  msg = "Наблюдатель перезапущен (PID $($alive[0].ProcessId))" } }
else { $results += @{ ok = $false; msg = "Наблюдатель не запустился - пришли отчёт из Диагностики" } }

# --- 5. vanilla .bin restore (optional, with confirmation) ---
$cfg1 = Get-MgConfig
$bkDir = Get-MajesticBackupDir $cfg1
if ($bkDir -and (Test-Path $bkDir)) {
    $binsInLauncher = (Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($binsInLauncher -eq 0) {
        Write-Host ""
        Write-Host "[?] В папке лаунчера нет бэкапов .bin (они в архиве)." -ForegroundColor Yellow
        Write-Host "    Вернуть их в лаунчер? Это возвращает Majestic в исходное состояние" -ForegroundColor Yellow
        Write-Host "    (MG-графика будет перезаписана ванилью при следующем запуске)." -ForegroundColor Yellow
        $r = Read-Host "Вернуть .bin в лаунчер? (да/нет)"
        if ($r -match '^(д|да|y|yes)$') {
            Restore-VanillaBackup -Cfg $cfg1
            $results += @{ ok = $true;  msg = "Vanilla .bin возвращены в лаунчер" }
        } else {
            $results += @{ ok = $true;  msg = ".bin остались в архиве (MG-графика защищена)" }
        }
    } else {
        $results += @{ ok = $true;  msg = "Бэкапы .bin уже в лаунчере ($binsInLauncher шт.)" }
    }
}

# --- summary ---
Write-Host ""
Write-Host "=== РЕЗУЛЬТАТЫ РЕМОНТА ==="
foreach ($r in $results) {
    if ($r.ok) { Write-Host "  [OK] $($r.msg)" -ForegroundColor Green }
    else { Write-Host "  [!] $($r.msg)" -ForegroundColor Red }
}
Write-Host ""
Write-Host "Если проблемы остались - запусти пункт Диагностика и пришли отчёт." -ForegroundColor Cyan
