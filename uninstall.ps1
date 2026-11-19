# MG Helper uninstall - by Bayra & Kavel1n
# Останавливает watcher кооперативно, удаляет задачу автозапуска и legacy Run-ключ,
# возвращает ванильные .bin лаунчеру. Бэкапы и эталон сохраняет.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Uninstall'

$common = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $common) { . $common }

# 1. cooperative stop
try { [System.Threading.EventWaitHandle]::OpenExisting('Local\MG_Helper_Stop').Set() | Out-Null } catch {}
Start-Sleep -Seconds 3

# 2. fallback: precise kill - never touches this uninstall process
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 3. autostart: scheduled task + legacy mechanisms
schtasks /Delete /TN 'MG_Helper_Watcher' /F 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host '[i] задача автозапуска не найдена (уже удалена).' -ForegroundColor DarkGray }
schtasks /Delete /TN 'MG_Helper_Watchdog' /F 2>&1 | Out-Null
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue

# 4. restore vanilla bins so Majestic does not hit error 1002
if (Test-Path -LiteralPath $common) {
    $cfg = Get-MgConfig
    if ((Ensure-BinsRestored -Cfg $cfg) -eq 'restored') {
        Write-Host '[+] Ванильные .bin возвращены лаунчеру.' -ForegroundColor Green
    }
}

Write-Host '[+] Watcher остановлен, автозапуск удалён.' -ForegroundColor Green
$sz = (Get-ChildItem "$env:LOCALAPPDATA\MG_Helper" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB
Write-Host ("Бэкапы и архивы остались: {0} ({1:N1} ГБ). Удали папку вручную, если не нужны." -f "$env:LOCALAPPDATA\MG_Helper", $sz)
