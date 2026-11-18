# Removes autostart entry, watchdog task and stops the watcher. Keeps your backups.
# Used as source for 0-uninstall.bat (EncodedCommand).
# by Bayra & Kavel1n
$host.UI.RawUI.WindowTitle = 'MG Helper - Uninstall'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher|MG_Helper' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "GTASettingsWatcher" -ErrorAction SilentlyContinue
schtasks /Delete /TN "MG_Helper_Watchdog" /F 2>&1 | Out-Null
Write-Host "[+] Watcher stopped, autostart and watchdog removed." -ForegroundColor Green
Write-Host "    Backups kept in %LOCALAPPDATA%\MG_Helper"
pause
