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
    # REVIEW-#5: real XML validation instead of a grep - a torn file with an
    # opening tag must not pass (length>100 checked via Test-GoldenValid for
    # golden files, Test-ValidSettingsXml for the rest)
    if ((Test-Path -LiteralPath $c) -and (Test-ValidSettingsXml -Path $c) -and ((Get-Item -LiteralPath $c).Length -gt 100)) { $gSrc = $c; break }
}
if ($gSrc -and ($gSrc -ne $Golden)) {
    # MG-CR-010: healing from the LIVE settings.xml may replace the golden the
    # user actually wanted - confirm before writing
    if ($gSrc -eq $cfg0.settingsXml) {
        Write-Host ""
        Write-Host "[?] Надёжная копия эталона не найдена. Восстановить эталон из ТЕКУЩИХ настроек GTA V?" -ForegroundColor Yellow
        Write-Host "    Это может заменить ранее сохранённую конфигурацию текущими настройками игры." -ForegroundColor Yellow
        $rLive = Read-Host "Восстановить эталон из текущих настроек? (да/нет)"
        if ($rLive -notmatch '^(д|да|y|yes)$') {
            $results += @{ ok = $false; msg = "Эталон НЕ восстановлен из LIVE-настроек (отменено пользователем) - используйте [2] Reset settings" }
            $gSrc = $null
        }
    }
}
if ($gSrc -and ($gSrc -ne $Golden)) {
    New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
    $healBytes = [IO.File]::ReadAllBytes($gSrc)
    $healOk = $false
    if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) { $healOk = Write-Atomic -Path $Golden -Bytes $healBytes }
    else { try { [IO.File]::WriteAllBytes($Golden, $healBytes); $healOk = $true } catch { $healOk = $false } }
    if ($healOk -and (Test-GoldenValid $Golden)) {
        $msg = "Эталон восстановлен из $((Split-Path $gSrc -Leaf))"
        if ($gSrc -eq $cfg0.settingsXml) { $msg += " (LIVE settings - проверьте, что это нужный файл!)" }
        $results += @{ ok = $true;  msg = $msg }
    } else {
        $results += @{ ok = $false; msg = "Не удалось записать восстановленный эталон (файл заблокирован?)" }
    }
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
    exit 1
}
'' | powershell -NoProfile -ExecutionPolicy Bypass -File $installer 2>&1 | ForEach-Object { Write-Host "  $_" }

# --- 4. verify watcher process is alive after installer restart ---
# REVIEW-#21 (installer part): wait for the READY marker, not just a process
$readyFile = Join-Path $HelperDir 'watcher.ready'
$ready = $false
for ($w = 0; $w -lt 30; $w++) {
    Start-Sleep -Seconds 1
    $alive = @(Get-WatcherProcess)
    if ($alive.Count -gt 0 -and (Test-Path -LiteralPath $readyFile)) { $ready = $true; break }
}
if (-not $ready) { Start-Sleep -Seconds 2; $alive = @(Get-WatcherProcess) }
if ($ready) { $results += @{ ok = $true;  msg = "Наблюдатель перезапущен и ГОТОВ (PID $($alive[0].ProcessId))" } }
elseif ($alive.Count -gt 0) { $results += @{ ok = $false; msg = "Наблюдатель запущен, но маркер READY не появился за 30 с - смотри watcher.log" } }
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
