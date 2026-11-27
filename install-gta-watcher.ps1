# MG Helper installer v6 - by Bayra & Kavel1n
# Deploys the package to %LOCALAPPDATA%\MG_Helper, registers autostart
# (logon + 10-min repeat), pins config, starts the watcher.
# Single source of truth: the .ps1 files in THIS folder are deployed verbatim.
[CmdletBinding()]
# -Force разрешает осознанный откат на более старую версию (см. guard ниже)
param([switch]$Force)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - by Bayra & Kavel1n'

# remove Mark-of-the-Web from package files (MG-CR-018: scoped to runnable
# package extensions, counted and reported - not a blanket sweep)
$unblocked = 0
Get-ChildItem $PSScriptRoot -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.ps1', '.bat', '.cs' } |
    ForEach-Object {
        try { Unblock-File -LiteralPath $_.FullName -ErrorAction Stop; $unblocked++ } catch {}
    }
Write-Host "[i] Mark-of-the-Web cleared on $unblocked package file(s)." -ForegroundColor DarkGray

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

# guard: refuse to overwrite a NEWER install unless -Force (downgrade protection)
$packageVersion = '0.0.0'
try { $packageVersion = [string](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'version.json') -Raw | ConvertFrom-Json).version } catch {}
$liveVersion = $null
try { $liveVersion = [string](Get-Content -LiteralPath (Join-Path $HelperDir 'version.json') -Raw | ConvertFrom-Json).version } catch {}
if ((Get-Command Test-InstallDowngrade -ErrorAction SilentlyContinue) -and (Test-InstallDowngrade -LiveVersion $liveVersion -PackageVersion $packageVersion) -and -not $Force) {
    Write-Host "[!] В папке уже стоит версия $liveVersion, а пакет - $packageVersion." -ForegroundColor Red
    Write-Host "    Затирать более новую установку старым пакетом нельзя. Осознанный откат: -Force." -ForegroundColor Yellow
    Write-Host "    Резервные копии: backups\2.6.1 в рабочем каталоге разработки." -ForegroundColor DarkGray
    exit 1
}
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
    'restore-mg-snapshot.ps1', 'restore-golden-history.ps1', 'save-custom-profile.ps1',
    'apply-custom-profile.ps1', 'update-helper.ps1', 'install-gta-watcher.ps1',
    'MgHelper.Core.ps1', 'CoreDecisions.cs', 'HelperPipe.cs', 'MG-Helper-Host.cs', 'MG-Helper-Tray.cs', 'MGCore.cs', 'version.json'
)
$utf8bom = [Text.UTF8Encoding]::new($true)
# MG-CR-019: staged deployment - everything is copied into a staging folder,
# VERIFIED there (present, non-empty, BOM on ps1, version.json parses), and
# only then promoted into HelperDir. A mid-deploy failure never leaves a
# mixed-version install; the previous deployment stays intact.
$staging = Join-Path $HelperDir (".staging-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
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
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    $dstFile = Join-Path $staging $f
    if ($f -like '*.ps1') {
        # ps1 files get BOM (PS 5.1 + Cyrillic), other files copied verbatim
        $bytes = [IO.File]::ReadAllBytes($srcFile)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom) {
            $txt = [Text.Encoding]::UTF8.GetString($bytes)
            [IO.File]::WriteAllText($dstFile, $txt, $utf8bom)
        } else {
            Copy-Item -LiteralPath $srcFile $dstFile -Force
        }
        continue
    }
    Copy-Item -LiteralPath $srcFile $dstFile -Force
}
# verify the staging copy BEFORE promoting it
$deployProblems = @()
foreach ($f in $deploy) {
    $dstFile = Join-Path $staging $f
    if (-not (Test-Path -LiteralPath $dstFile)) { continue }   # version.json optional
    if ((Get-Item -LiteralPath $dstFile).Length -eq 0) { $deployProblems += "$f is empty" }
    if ($f -like '*.ps1') {
        $b = [IO.File]::ReadAllBytes($dstFile)
        if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $deployProblems += "$f has no BOM" }
        $perr = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($dstFile, [ref]$null, [ref]$perr)
        if ($perr -and $perr.Count) { $deployProblems += "$f parse error: $($perr[0].Message)" }
    }
    if ($f -eq 'version.json') {
        try { $null = (Get-Content -LiteralPath $dstFile -Raw | ConvertFrom-Json).version } catch { $deployProblems += 'version.json is not valid JSON' }
    }
}
if ($deployProblems.Count -gt 0) {
    Write-Host '[!] Staged package verification FAILED - the previous deployment stays intact:' -ForegroundColor Red
    $deployProblems | ForEach-Object { Write-Host "      - $_" -ForegroundColor Red }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
# promote: staging -> HelperDir (same self-copy guard)
foreach ($f in $deploy) {
    $dstFile = Join-Path $staging $f
    if (-not (Test-Path -LiteralPath $dstFile)) { continue }
    $finalPath = Join-Path $HelperDir $f
    if ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot $f)) -eq [IO.Path]::GetFullPath($finalPath)) { continue }
    Copy-Item -LiteralPath $dstFile $finalPath -Force
}
Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
# MG-CR-017 (part 1): record SHA256 of every deployed file so a user (or we,
# remotely via Diagnose) can verify the installed copy against the package
Get-ChildItem $HelperDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in $deploy -or $_.Name -eq 'MG-Helper-Host.exe' } |
    ForEach-Object { "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.Name } |
    Set-Content -LiteralPath (Join-Path $HelperDir 'package_hashes.txt') -Encoding ASCII
Write-Host "[+] Package scripts deployed and verified." -ForegroundColor Green

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
# MG-CR-020: success message only when the save actually succeeded
if (-not (Save-MgConfig $cfg)) {
    Write-Host '[!] config.json could NOT be saved - discovery will repeat next start.' -ForegroundColor Yellow
} else {
    Write-Host "[i] config.json written (discovered paths are cached there)." -ForegroundColor DarkGray
}
# ROADMAP 2.3: record the machine identity for the golden key
if (Save-GoldenKey -Cfg $cfg) { Write-Host '[i] golden key recorded (variant + GPU).' -ForegroundColor DarkGray }

# ------------------------------------------------------------
# 5. autostart: one scheduled task (logon + 10-min repeat), mutex-protected
# ------------------------------------------------------------
$watcherDst = Join-Path $HelperDir 'gta-settings-watcher.ps1'
# cooperative stop, then precise kill - never touches this installer or the menu
try { [System.Threading.EventWaitHandle]::OpenExisting('Local\MG_Helper_Stop').Set() | Out-Null } catch {}
# REVIEW-#19: the watcher can be inside a multi-GB copy that ignores nothing -
# give it time to notice the stop event (its loop polls every 5 s)
Start-Sleep -Seconds 7
# REVIEW-#9: single shared watcher-process filter (excludes -Diagnose too)
Get-WatcherProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -Name 'MG-Helper-Tray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

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

# ------------------------------------------------------------
# ROADMAP phase 3 (strangler): BETA C# core - config "coreMode": "csharp"
# switches the task from the PS watcher to the compiled MGCore.exe.
# Default stays 'ps'. Any compile/smoke failure -> automatic PS fallback.
# ------------------------------------------------------------
$coreMode = 'ps'
try {
    $cfgRaw = Get-Content -LiteralPath (Join-Path $HelperDir 'config.json') -Raw -ErrorAction Stop
    $m = [regex]::Match($cfgRaw, '"coreMode"\s*:\s*"([^"]+)"')
    if ($m.Success) { $coreMode = $m.Groups[1].Value }
} catch { }
$coreExe = Join-Path $HelperDir 'MGCore.exe'
$coreSrc = Join-Path $PSScriptRoot 'MGCore.cs'
$coreOk = $false
if ($coreMode -eq 'csharp') {
    try {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText($coreSrc)) `
            -ReferencedAssemblies @('System.Web.Extensions','System.Xml') `
            -OutputAssembly $coreExe -OutputType WindowsApplication -ErrorAction Stop
        $smokeScript2 = Join-Path $HelperDir 'core_smoke.ps1'
        Set-Content -LiteralPath $smokeScript2 -Value 'exit 0' -Encoding ASCII
        $spc = Start-Process $coreExe -ArgumentList '-Smoke', "`"$smokeScript2`"" -PassThru -WindowStyle Hidden
        if (-not $spc.WaitForExit(20000)) { try { $spc.Kill() } catch {}; throw 'core smoke timeout' }
        if ($spc.ExitCode -ne 0) { throw "core smoke exit code $($spc.ExitCode)" }
        Remove-Item -LiteralPath $smokeScript2 -Force -ErrorAction SilentlyContinue
        Write-Host '[+] MGCore beta compiled and smoke-run OK (coreMode=csharp).' -ForegroundColor Green
        $coreOk = $true
    } catch {
        Write-Host "[!] MGCore beta failed: $($_.Exception.Message) - falling back to the PS watcher." -ForegroundColor Yellow
        $coreOk = $false
    }
}
if ($coreOk) {
    $action = New-ScheduledTaskAction -Execute $coreExe -Argument "`"$watcherDst`"" -WorkingDirectory $HelperDir
    Write-Host '[i] beta C# core ACTIVE - feedback welcome via Issues.' -ForegroundColor Green
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
$fallbackMode = $false
try {
    Register-ScheduledTask @reg | Out-Null
    $regOk = $true
} catch {
    $tr = if ($hostExe) { "`"$hostExe`" `"$watcherDst`"" } else { "`"$exe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherDst`"" }
    schtasks /Create /F /SC MINUTE /MO 10 /TN 'MG_Helper_Watcher' /TR $tr | Out-Null
    $regOk = ($LASTEXITCODE -eq 0)
    $fallbackMode = $regOk
}
# MG-CR-007: verify the task ACTUALLY exists with a working action; the schtasks
# fallback loses the logon trigger (10-min repeat only) - say so honestly
if ($regOk) {
    $taskCheck = Get-ScheduledTask -TaskName 'MG_Helper_Watcher' -ErrorAction SilentlyContinue
    if (-not $taskCheck) {
        Write-Host '[!] Task registered but NOT found in the scheduler - install is incomplete.' -ForegroundColor Red
        exit 1
    }
    if ($fallbackMode) {
        Write-Host '[+] Watchdog task registered (FALLBACK: 10-min repeat only - logon trigger unavailable).' -ForegroundColor Yellow
        Write-Host '    The watcher still starts within 10 minutes after logon and stays running.' -ForegroundColor DarkGray
    } else {
        Write-Host '[+] Watchdog task registered (logon + 10-min repeat).' -ForegroundColor Green
    }
}
else {
    Write-Host '[!] Watchdog task registration failed.' -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# 6. start watcher (via the task - no console flash, no focus steal).
#    MG-CR-021: wait for the watcher READY marker (mutex held + config loaded
#    + state initialised), not just process existence.
# ------------------------------------------------------------
$readyFile = Join-Path $HelperDir 'watcher.ready'
Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue   # stale marker from a previous run
Remove-Item -LiteralPath (Join-Path $HelperDir 'tray_exit.flag') -Force -ErrorAction SilentlyContinue   # fresh install: tray comes back
Start-ScheduledTask -TaskName 'MG_Helper_Watcher'
$ready = $false
for ($w = 0; $w -lt 30; $w++) {
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $readyFile) { $ready = $true; break }
}
# the active core may be MGCore.exe (no powershell process) - the READY marker
# is the source of truth; PS-process check is only a bonus for the PS core
$alive = @(Get-WatcherProcess -ExcludePid $PID)
$alive += @(Get-Process -Name 'MGCore' -ErrorAction SilentlyContinue)
if ($ready) {
    $pidTxt = if ($alive.Count -gt 0) { " (PID $($alive[0].Id))" } else { "" }
    Write-Host "[+] Watcher v$(Get-PkgVersion) is running and READY$pidTxt." -ForegroundColor Green
} elseif ($alive.Count -gt 0) {
    Write-Host "[i] Watcher process is running but the READY marker did not appear in 30 s." -ForegroundColor Yellow
    Write-Host "    Check watcher.log - the watcher may still be initialising." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "[!] Watcher failed to start - run MG-Helper.bat > [8] Diagnose." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# 7. tray icon (ROADMAP 5.1): compiled from readable source at install,
#    started at logon via a Startup-folder shortcut (no admin, no task).
# ------------------------------------------------------------
$trayExe = Join-Path $HelperDir 'MG-Helper-Tray.exe'
$traySrc = Join-Path $PSScriptRoot 'MG-Helper-Tray.cs'
$trayOk = $false
try {
    # stop a previous tray instance before recompiling over its exe
    Get-Process -Name 'MG-Helper-Tray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($traySrc)) `
        -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing', 'System.Management') `
        -OutputAssembly $trayExe -OutputType WindowsApplication -ErrorAction Stop
    if ((Get-Item -LiteralPath $trayExe).Length -gt 0) { $trayOk = $true }
    if ($trayOk) { Write-Host '[+] Tray icon compiled.' -ForegroundColor Green }
} catch {
    Write-Host "[!] Tray icon compile failed: $($_.Exception.Message)" -ForegroundColor Yellow
    $trayOk = $false
}
if ($trayOk) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\MG Helper Tray.lnk'))
        $lnk.TargetPath = $trayExe
        $lnk.WorkingDirectory = $HelperDir
        $lnk.Save()
        Start-Process $trayExe
        Write-Host '[+] Tray icon started (also launches at logon).' -ForegroundColor Green
    } catch {
        Write-Host "[!] Tray startup shortcut failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host '[i] Tray icon unavailable - everything else works; the menu stays the control centre.' -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "Done! by Bayra & Kavel1n" -ForegroundColor Cyan

