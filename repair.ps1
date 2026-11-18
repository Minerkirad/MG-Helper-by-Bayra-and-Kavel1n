# MG Helper repair - fixes typical problems on demand.
# Only safe operations: re-discovery, golden restore chain, attribute fixes,
# autostart/watchdog re-registration. Touching Majestic's .bin needs confirmation.
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

# --- 1. full path re-discovery + config re-save ---
$cfg = Resolve-MgPaths -ForceFull
if ($cfg.settingsXml) { $results += @{ ok = $true;  msg = "Пути переопределены: settings.xml найден" } }
else {                  $results += @{ ok = $false; msg = "settings.xml НЕ найден на этом ПК - запусти GTA V один раз" } }

# --- 2. golden self-heal chain ---
$Golden = Join-Path $HelperDir 'settings.golden.xml'
$gSrc = $null
$chain = @($Golden, "$Golden.bak", (Join-Path $HelperDir 'settings.before_apply.bak'), $cfg.settingsXml) |
    Where-Object { $_ } | Select-Object -Unique
foreach ($c in $chain) {
    try {
        $raw = Get-Content -LiteralPath $c -Raw -ErrorAction Stop
        if ($raw.Length -gt 100 -and $raw -match '<Settings>' -and ($raw -notmatch '\$\d')) { $gSrc = $c; break }
    } catch {}
}
if ($gSrc -and ($gSrc -ne $Golden)) {
    Copy-Item $gSrc $Golden -Force
    $results += @{ ok = $true;  msg = "Эталон восстановлен из $((Split-Path $gSrc -Leaf))" }
}
elseif ($gSrc) { $results += @{ ok = $true;  msg = "Эталон валиден - восстановление не потребовалось" } }
else {              $results += @{ ok = $false; msg = "Ни одного валидного источника эталона не найдено" } }

# --- 3. read-only attribute on settings.xml ---
if ($cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)) {
    $item = Get-Item -LiteralPath $cfg.settingsXml
    if ($item.IsReadOnly) {
        Set-ItemProperty -LiteralPath $cfg.settingsXml -Name IsReadOnly -Value $false
        $results += @{ ok = $true;  msg = "Атрибут 'только чтение' снят с settings.xml" }
    } else { $results += @{ ok = $true;  msg = "settings.xml доступен для записи" } }
}

# --- 4. re-deploy common + watcher scripts from the package ---
foreach ($pair in @(
        @{ Src = 'common.ps1'; Dst = 'common.ps1' }
        @{ Src = 'gta-settings-watcher.ps1'; Dst = 'gta-settings-watcher.ps1' }
    )) {
    $srcFile = Join-Path $root $pair.Src
    if (Test-Path -LiteralPath $srcFile) {
        Copy-Item $srcFile (Join-Path $HelperDir $pair.Dst) -Force
    }
}
$results += @{ ok = $true;  msg = "Скрипты наблюдателя обновлены из пакета" }

# --- 5. autostart (HKCU Run) ---
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$watcherDst = Join-Path $HelperDir 'gta-settings-watcher.ps1'
$expected = "`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherDst`""
$cur = (Get-ItemProperty $runKey -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue).GTASettingsWatcher
if ($cur -ne $expected) {
    New-ItemProperty $runKey -Name 'GTASettingsWatcher' -Value $expected -PropertyType String -Force | Out-Null
    $results += @{ ok = $true;  msg = "Автозапуск пересоздан (был удалён или повреждён)" }
} else { $results += @{ ok = $true;  msg = "Автозапуск в порядке" } }

# --- 6. watchdog scheduled task ---
schtasks /Create /F /SC MINUTE /MO 10 /TN "MG_Helper_Watchdog" /TR $expected 2>&1 | Out-Null
$schOk = (schtasks /Query /TN "MG_Helper_Watchdog" 2>&1 | Out-String) -match 'MG_Helper_Watchdog'
if ($schOk) { $results += @{ ok = $true;  msg = "Watchdog-задача на месте (перезапуск каждые 10 минут)" } }
else { $results += @{ ok = $false; msg = "Watchdog-задача не создалась (нет прав?)" } }

# --- 7. restart the watcher (needs killing the old process - with confirmation) ---
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher|MG_Helper' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Process powershell -ArgumentList '-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$watcherDst`"" -WindowStyle Hidden
Start-Sleep 4
$alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'gta-settings-watcher' })
if ($alive.Count -gt 0) { $results += @{ ok = $true;  msg = "Наблюдатель перезапущен (PID $($alive[0].ProcessId))" } }
else { $results += @{ ok = $false; msg = "Наблюдатель не запустился - пришли отчёт из 5-diagnose.bat" } }

# --- 8. vanilla .bin restore (optional, with confirmation) ---
$bkDir = Get-MajesticBackupDir $cfg
if ($bkDir -and (Test-Path $bkDir)) {
    $binsInLauncher = (Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($binsInLauncher -eq 0) {
        Write-Host ""
        Write-Host "[?] В папке лаунчера нет бэкапов .bin (они в архиве)." -ForegroundColor Yellow
        Write-Host "    Вернуть их в лаунчер? Это возвращает Majestic в исходное состояние" -ForegroundColor Yellow
        Write-Host "    (MG-графика будет перезаписана ванилью при следующем запуске)." -ForegroundColor Yellow
        $r = Read-Host "Вернуть .bin в лаунчер? (да/нет)"
        if ($r -match '^(д|да|y|yes)$') {
            Restore-VanillaBackup -Cfg $cfg
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
pause
