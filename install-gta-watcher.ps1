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
    exit 1
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
    'restore-mg-snapshot.ps1', 'install-gta-watcher.ps1', 'MG-Helper-Host.cs', 'version.json'
)
$utf8bom = [Text.UTF8Encoding]::new($true)
foreach ($f in $deploy) {
    $srcFile = Join-Path $PSScriptRoot $f
    # Repair runs the DEPLOYED installer: never copy a file onto itself
    if ([IO.Path]::GetFullPath($srcFile) -eq [IO.Path]::GetFullPath((Join-Path $HelperDir $f))) { continue }
    if (-not (Test-Path -LiteralPath $srcFile)) {
        if ($f -eq 'version.json') {
            Write-Host '[i] version.json missing - using fallback version.' -ForegroundColor DarkGray
            continue
        }
        Write-Host "[!] $f missing next to this installer - re-download the whole package." -ForegroundColor Red
        exit 1
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

# compile the hidden host (GUI subsystem, no console window at all).
# Compiled ON THE MACHINE from readable source - no binaries shipped in the ZIP.
$hostExe = Join-Path $HelperDir 'MG-Helper-Host.exe'
$hostSrc = Join-Path $PSScriptRoot 'MG-Helper-Host.cs'
try {
    $cs = [IO.File]::ReadAllText($hostSrc)
    Add-Type -TypeDefinition $cs -OutputAssembly $hostExe -OutputType WindowsApplication -ErrorAction Stop
    Write-Host "[+] Hidden host compiled (no console window at all)." -ForegroundColor Green
} catch {
    Write-Host "[!] Cannot compile hidden host: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "    Falling back to S4U task (runs non-interactive, also no window)." -ForegroundColor Yellow
    $hostExe = $null
}

# launchability smoke: AppLocker/WDAC/AV often block unsigned exes from
# LOCALAPPDATA - the task would register but the watcher would never start.
if ($hostExe) {
    try {
        $smokeScript = Join-Path $HelperDir 'host_smoke.ps1'
        Set-Content -LiteralPath $smokeScript -Value 'exit 0' -Encoding ASCII
        $sp = Start-Process $hostExe -ArgumentList '-Smoke', "`"$smokeScript`"" -PassThru -WindowStyle Hidden
        if (-not $sp.WaitForExit(20000)) {
            try { $sp.Kill() } catch {}
            throw 'host smoke timeout (20 s)'
        }
        if ($sp.ExitCode -ne 0) { throw "host smoke exit code $($sp.ExitCode)" }
        Remove-Item -LiteralPath $smokeScript -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Hidden host smoke-run OK." -ForegroundColor DarkGray
    } catch {
        Remove-Item -LiteralPath $smokeScript -Force -ErrorAction SilentlyContinue
        Write-Host "[!] Hidden host cannot run on this machine: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    (AppLocker/WDAC/antivirus likely) - falling back to S4U task." -ForegroundColor Yellow
        $hostExe = $null
    }
}

if ($hostExe) {
    $action = New-ScheduledTaskAction -Execute $hostExe -Argument "`"$watcherDst`"" -WorkingDirectory $HelperDir
} else {
    $argLine = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherDst`""
    $action = New-ScheduledTaskAction -Execute $exe -Argument $argLine
}

$tLogon  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
$set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
$reg = @{ TaskName='MG_Helper_Watcher'; Action=$action; Trigger=@($tLogon,$tRepeat); Settings=$set
          Description='MG Helper watcher (by Bayra & Kavel1n)'; Force=$true; ErrorAction='Stop' }
if (-not $hostExe) {
    # plan B: S4U - the task runs non-interactive, so no window is ever shown
    $reg.Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
}
$regOk = $false
try {
    Register-ScheduledTask @reg | Out-Null
    $regOk = $true
} catch {
    $tr = if ($hostExe) { "`"$hostExe`" `"$watcherDst`"" } else { "`"$exe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherDst`"" }
    schtasks /Create /F /SC MINUTE /MO 10 /TN 'MG_Helper_Watcher' /TR $tr | Out-Null
    $regOk = ($LASTEXITCODE -eq 0)
}
if ($regOk) { Write-Host '[+] Watchdog task registered (logon + 10-min repeat).' -ForegroundColor Green }
else {
    Write-Host '[!] Watchdog task registration failed.' -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# 6. start watcher (via the task - no console flash, no focus steal)
# ------------------------------------------------------------
Start-ScheduledTask -TaskName 'MG_Helper_Watcher'
Start-Sleep 6
$alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher\.ps1' -and $_.ProcessId -ne $PID -and $_.CommandLine -notmatch '-Diagnose' })
if ($alive.Count -gt 0) {
    Write-Host "[+] Watcher v$(Get-PkgVersion) is running (PID $($alive[0].ProcessId))." -ForegroundColor Green
    Write-Host ""
    Write-Host "Done! by Bayra & Kavel1n" -ForegroundColor Cyan
} else {
    Write-Host "[!] Watcher failed to start - run MG-Helper.bat > [8] Diagnose." -ForegroundColor Red
    exit 1
}

