# MG Helper installer v6 - by Bayra & Kavel1n
# Deploys the package to %LOCALAPPDATA%\MG_Helper, registers autostart
# (logon + 10-min repeat), pins config, starts the watcher.
# Single source of truth: the .ps1 files in THIS folder are deployed verbatim.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - by Bayra & Kavel1n'

# remove Mark-of-the-Web from package files
Get-ChildItem $PSScriptRoot -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'common.ps1')

# ------------------------------------------------------------
# 0. locate settings.xml (multi-strategy)
# ------------------------------------------------------------
$Settings = Find-SettingsXml
if (-not $Settings) {
    Write-Host "[!] Could not find Rockstar Games\GTA V\settings.xml on this PC." -ForegroundColor Red
    Write-Host "    Run GTA V once first, then run this installer again." -ForegroundColor Yellow
    pause; exit 1
}
Write-Host "[i] settings.xml found: $Settings"

$game = Find-GtaGameRoot
if ($game) { Write-Host "[i] GTA install: $($game.root) ($($game.variant))" }

# ------------------------------------------------------------
# 1. folders
# ------------------------------------------------------------
$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
$legacyBackup = Join-Path (Split-Path $Settings) '_settings_backup'

# migrate legacy golden if present
$legacyGolden = Join-Path $legacyBackup 'settings.golden.xml'
$golden = Join-Path $HelperDir 'settings.golden.xml'
if (-not (Test-Path -LiteralPath $golden) -and (Test-Path -LiteralPath $legacyGolden)) {
    Copy-Item -LiteralPath $legacyGolden $golden -Force
    Write-Host "[i] Migrated existing golden from legacy location." -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# 2. deploy package scripts to HelperDir (verbatim)
# ------------------------------------------------------------
$deploy = @(
    'common.ps1', 'gta-settings-watcher.ps1', 'MG-Helper.ps1', 'MG-Helper.bat',
    'diagnose.ps1', 'uninstall.ps1', 'repair.ps1', 'reset-settings.ps1',
    'import-settings.ps1', 'clean-majestic-cache.ps1', 'max-fps.ps1', 'cut-shadows.ps1',
    'restore-mg-snapshot.ps1', 'version.json'
)
$utf8bom = [Text.UTF8Encoding]::new($true)
foreach ($f in $deploy) {
    $srcFile = Join-Path $PSScriptRoot $f
    if (-not (Test-Path -LiteralPath $srcFile)) {
        if ($f -eq 'version.json') {
            Write-Host '[i] version.json missing - using fallback version.' -ForegroundColor DarkGray
            continue
        }
        Write-Host "[!] $f missing next to this installer - re-download the whole package." -ForegroundColor Red
        pause; exit 1
    }
    if ($f -like '*.ps1') {
        # ps1 files get BOM (PS 5.1 + Cyrillic), other files copied verbatim
        $bytes = [IO.File]::ReadAllBytes($srcFile)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom) {
            $txt = [Text.Encoding]::UTF8.GetString($bytes)
            [IO.File]::WriteAllText((Join-Path $HelperDir $f), $txt, $utf8bom)
        } else {
            Copy-Item -LiteralPath $srcFile (Join-Path $HelperDir $f) -Force
        }
        continue
    }
    Copy-Item -LiteralPath $srcFile (Join-Path $HelperDir $f) -Force
}
Write-Host "[+] Package scripts deployed." -ForegroundColor Green

# ------------------------------------------------------------
# 3. golden: migrate/create, self-heal chain
# ------------------------------------------------------------
if (-not (Test-GoldenValid $golden)) {
    $src = Get-ValidGolden -CfgSettingsXml $Settings
    if ($src -and ($src.path -ne $golden)) {
        Copy-Item -LiteralPath $src.path $golden -Force
        Write-Host "[+] Golden healed from $($src.path)" -ForegroundColor Green
    } else {
        Copy-Item -LiteralPath $Settings $golden -Force
        Write-Host "[+] Golden created from current settings." -ForegroundColor Green
    }
}

# ------------------------------------------------------------
# 4. config pin (discovered paths cached, manual overrides win)
# ------------------------------------------------------------
$cfg = Get-MgConfig
$cfg.settingsXml = $Settings
$mgFound = Find-MiamiGraphicsDir
if ($mgFound) { $cfg.miamiGraphicsDir = $mgFound }
$mjFound = Find-MajesticJson
if ($mjFound) { $cfg.majesticJson = $mjFound }
Save-MgConfig $cfg
Write-Host "[i] config.json written (discovered paths are cached there)." -ForegroundColor DarkGray

# ------------------------------------------------------------
# 5. autostart: one scheduled task (logon + 10-min repeat), mutex-protected
# ------------------------------------------------------------
$watcherDst = Join-Path $HelperDir 'gta-settings-watcher.ps1'
# cooperative stop, then precise kill - never touches this installer or the menu
try { [System.Threading.EventWaitHandle]::OpenExisting('Local\MG_Helper_Stop').Set() | Out-Null } catch {}
Start-Sleep -Seconds 2
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# migration: remove old mechanisms
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue
schtasks /Delete /TN 'MG_Helper_Watchdog' /F 2>&1 | Out-Null

$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argLine = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherDst`""
$action = New-ScheduledTaskAction -Execute $exe -Argument $argLine
$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
$set = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
$regOk = $false
try {
    Register-ScheduledTask -TaskName 'MG_Helper_Watcher' -Action $action -Trigger @($tLogon, $tRepeat) -Settings $set -Description 'MG Helper watcher (by Bayra & Kavel1n)' -Force -ErrorAction Stop | Out-Null
    $regOk = $true
} catch {
    schtasks /Create /F /SC MINUTE /MO 10 /TN 'MG_Helper_Watcher' /TR ("`"$exe`" $argLine") | Out-Null
    $regOk = [bool](Get-ScheduledTask -TaskName 'MG_Helper_Watcher' -ErrorAction SilentlyContinue)
}
if ($regOk) { Write-Host '[+] Watchdog task registered (logon + 10-min repeat).' -ForegroundColor Green }
else { Write-Host '[!] Watchdog task registration failed.' -ForegroundColor Red }

# ------------------------------------------------------------
# 6. start watcher
# ------------------------------------------------------------
Start-Process $exe -ArgumentList $argLine -WindowStyle Hidden
Start-Sleep 4
$alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher\.ps1' -and $_.ProcessId -ne $PID })
if ($alive.Count -gt 0) {
    Write-Host "[+] Watcher v1.6.2 is running (PID $($alive[0].ProcessId))." -ForegroundColor Green
    Write-Host ""
    Write-Host "Done! by Bayra & Kavel1n" -ForegroundColor Cyan
} else {
    Write-Host "[!] Watcher failed to start - run MG-Helper.bat > [8] Diagnose." -ForegroundColor Red
}
pause

