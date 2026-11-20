# MG Helper uninstall - by Bayra & Kavel1n
# Останавливает watcher кооперативно, удаляет задачу автозапуска и legacy Run-ключ,
# возвращает ванильные .bin лаунчеру. Бэкапы и эталон сохраняет.
# MG-CR-012: честный итог по каждому действию - никаких безусловных "[+]".
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Uninstall'

$common = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $common) { . $common }

$results = @()

# 1. cooperative stop
try { [System.Threading.EventWaitHandle]::OpenExisting('Local\MG_Helper_Stop').Set() | Out-Null } catch {}
# REVIEW-#19: give the watcher time to notice (it polls every 5 s and may be
# inside a multi-GB archive copy)
Start-Sleep -Seconds 7

# 2. fallback: precise kill - never touches this uninstall process
Get-WatcherProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$left = @(Get-WatcherProcess)
if ($left.Count -eq 0) { $results += @{ ok = $true;  msg = 'Watcher остановлен' } }
else { $results += @{ ok = $false; msg = "Watcher ВСЁ ЕЩЁ ЗАПУЩЕН ($($left.Count) процессов) - закрой вручную" } }

# 3. autostart: scheduled task + legacy mechanisms
schtasks /Delete /TN 'MG_Helper_Watcher' /F 2>&1 | Out-Null
schtasks /Delete /TN 'MG_Helper_Watchdog' /F 2>&1 | Out-Null
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue
$taskLeft = Get-ScheduledTask -TaskName 'MG_Helper_Watcher' -ErrorAction SilentlyContinue
$runLeft = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue).GTASettingsWatcher
if (-not $taskLeft -and -not $runLeft) { $results += @{ ok = $true;  msg = 'Автозапуск удалён (задача + legacy Run-ключ)' } }
else { $results += @{ ok = $false; msg = 'Автозапуск УДАЛИТЬСЯ НЕ ПОЛНОСТЬЮ - проверь планировщик задач' } }

# 4. restore vanilla bins so Majestic does not hit error 1002
if (Test-Path -LiteralPath $common) {
    $cfg = Get-MgConfig
    $bs = Ensure-BinsRestored -Cfg $cfg
    if ($bs -eq 'restored') { $results += @{ ok = $true;  msg = 'Ванильные .bin возвращены лаунчеру' } }
    elseif ($bs -eq 'present') { $results += @{ ok = $true;  msg = 'Ванильные .bin уже на месте у лаунчера' } }
    elseif ($bs -in @('partial', 'failed')) { $results += @{ ok = $false; msg = "Ванильные .bin восстановлены ЧАСТИЧНО или с ошибкой ($bs) - возможна ошибка 1002 при следующем запуске Majestic" } }
    else { $results += @{ ok = $true;  msg = '.bin не требовали восстановления (архива нет)' } }
}

# summary - honest, per action
Write-Host ''
Write-Host '=== РЕЗУЛЬТАТ УДАЛЕНИЯ ==='
$allOk = $true
foreach ($r in $results) {
    if ($r.ok) { Write-Host "  [OK] $($r.msg)" -ForegroundColor Green }
    else { Write-Host "  [!] $($r.msg)" -ForegroundColor Red; $allOk = $false }
}
Write-Host '  [OK] Бэкапы и эталон сохранены' -ForegroundColor Green
if (-not $allOk) { Write-Host '[!] Удаление завершилось НЕ ПОЛНОСТЬЮ - см. пункты с [!] выше.' -ForegroundColor Red }
$sz = (Get-ChildItem "$env:LOCALAPPDATA\MG_Helper" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB
Write-Host ("Бэкапы и архивы остались: {0} ({1:N1} ГБ). Удали папку вручную, если не нужны." -f "$env:LOCALAPPDATA\MG_Helper", $sz)
# REVIEW-#20: honest exit code - the menu relies on it
if ($allOk) { exit 0 } else { exit 1 }
