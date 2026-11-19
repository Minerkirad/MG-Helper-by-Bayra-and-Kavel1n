# MG Helper watcher v6 - by Bayra & Kavel1n
# State machine (Idle/InGame, persistent), adopt-on-exit policy,
# cooperative stop, log rotation, heartbeat. PS 5.1-safe.
# common.ps1 (dot-sourced) provides discovery/config/shared ops.
param(
    [switch]$Diagnose,
    [switch]$Foreground
)
$ErrorActionPreference = 'SilentlyContinue'

$HelperDir  = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden     = Join-Path $HelperDir 'settings.golden.xml'
$LogFile    = Join-Path $HelperDir 'watcher.log'
$StateFile  = Join-Path $HelperDir 'state.json'
$StopEvent  = 'Local\MG_Helper_Stop'
$MutexName  = 'Local\MG_Helper_Watcher'

. (Join-Path $PSScriptRoot 'common.ps1')

function Log($msg) {
    # rotate past 1 MB (keep one .old generation)
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 1MB)) {
            Move-Item -LiteralPath $LogFile "$LogFile.old" -Force
        }
    } catch {}
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    $line | Out-File -LiteralPath $LogFile -Append -Encoding UTF8
    if ($Foreground) { Write-Host $line }
}

function Snapshot-MgFiles {
    # saves a full copy of MG json settings (nothing is ever deleted)
    param($Cfg)
    try {
        $dirs = @()
        if ($Cfg.miamiGraphicsDir -and (Test-Path -LiteralPath $Cfg.miamiGraphicsDir)) { $dirs += $Cfg.miamiGraphicsDir }
        foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
            $c = Join-Path $root 'MiamiGraphics'
            if ((Test-Path -LiteralPath $c) -and ($dirs -notcontains $c)) { $dirs += $c }
        }
        if (@($dirs).Count -eq 0) { Log "[i] MG dirs not found - snapshot skipped"; return }
        $snapDir = Join-Path $HelperDir 'mg_snapshot'
        New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
        $n = 0
        foreach ($dir in $dirs) {
            $rootFlat = ($dir -replace '[:\\/]', '_')
            foreach ($f in (Get-ChildItem $dir -Recurse -Depth 2 -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $rel = ($rootFlat + '__' + $f.FullName.Substring($dir.Length).TrimStart('\')) -replace '[\\/]', '__'
                Copy-Item -LiteralPath $f.FullName (Join-Path $snapDir $rel) -Force
                $n++
            }
        }
        if ($n -gt 0) { Log "MG snapshot saved ($n files -> $snapDir)" }
    } catch {
        Log "[!] MG snapshot error: $_"
    }
}

function Clean-Dlccache {
    # archives dlccache .dat files into a backup folder instead of deleting (opt-in)
    param($Cfg)
    try {
        $cachePath = Get-MajesticCachePath $Cfg.majesticJson
        if (-not $cachePath -or -not (Test-Path "$cachePath\dlccache")) { return }
        $files = Get-ChildItem "$cachePath\dlccache" -Filter '*.dat' -ErrorAction SilentlyContinue
        if (-not $files) { return }
        $arc = Join-Path $HelperDir ("dlccache_backup\{0}" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        New-Item -ItemType Directory -Force -Path $arc | Out-Null
        $files | Move-Item -Destination $arc -Force -ErrorAction SilentlyContinue
        Log ("dlccache archived {0} files -> {1}" -f $files.Count, $arc)
    } catch {
        Log "[!] dlccache archive error: $_"
    }
}

function Save-State {
    # persistent state machine (atomic, survives watcher restarts)
    param([hashtable]$St)
    try {
        $json = $St | ConvertTo-Json -Depth 3
        $tmp = "$StateFile.tmp"
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $StateFile) { [IO.File]::Replace($tmp, $StateFile, $null) }
        else { Move-Item -LiteralPath $tmp $StateFile -Force }
    } catch {
        try { Remove-Item -LiteralPath "$StateFile.tmp" -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Snapshot-MgFiles {
    # saves a full copy of MG json settings (nothing is ever deleted)
    param($Cfg)
    try {
        $dirs = @()
        if ($Cfg.miamiGraphicsDir -and (Test-Path -LiteralPath $Cfg.miamiGraphicsDir)) { $dirs += $Cfg.miamiGraphicsDir }
        foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
            $c = Join-Path $root 'MiamiGraphics'
            if ((Test-Path -LiteralPath $c) -and ($dirs -notcontains $c)) { $dirs += $c }
        }
        if (@($dirs).Count -eq 0) { Log "[i] MG dirs not found - snapshot skipped"; return }
        $snapDir = Join-Path $HelperDir 'mg_snapshot'
        New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
        $n = 0
        foreach ($dir in $dirs) {
            $rootFlat = ($dir -replace '[:\\/]', '_')
            foreach ($f in (Get-ChildItem $dir -Recurse -Depth 2 -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $rel = ($rootFlat + '__' + $f.FullName.Substring($dir.Length).TrimStart('\')) -replace '[\\/]', '__'
                Copy-Item -LiteralPath $f.FullName (Join-Path $snapDir $rel) -Force
                $n++
            }
        }
        if ($n -gt 0) { Log "MG snapshot saved ($n files -> $snapDir)" }
    } catch {
        Log "[!] MG snapshot error: $_"
    }
}

function Clean-Dlccache {
    # archives dlccache .dat files into a backup folder instead of deleting (opt-in)
    param($Cfg)
    try {
        $cachePath = Get-MajesticCachePath $Cfg.majesticJson
        if (-not $cachePath -or -not (Test-Path "$cachePath\dlccache")) { return }
        $files = Get-ChildItem "$cachePath\dlccache" -Filter '*.dat' -ErrorAction SilentlyContinue
        if (-not $files) { return }
        $arc = Join-Path $HelperDir ("dlccache_backup\{0}" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        New-Item -ItemType Directory -Force -Path $arc | Out-Null
        $files | Move-Item -Destination $arc -Force -ErrorAction SilentlyContinue
        Log ("dlccache archived {0} files -> {1}" -f $files.Count, $arc)
    } catch {
        Log "[!] dlccache archive error: $_"
    }
}

function Save-State {
    # persistent state machine (atomic, survives watcher restarts)
    param([hashtable]$St)
    try {
        $json = $St | ConvertTo-Json -Depth 3
        $tmp = "$StateFile.tmp"
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $StateFile) { [IO.File]::Replace($tmp, $StateFile, $null) }
        else { Move-Item -LiteralPath $tmp $StateFile -Force }
    } catch {
        try { Remove-Item -LiteralPath "$StateFile.tmp" -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# ---------------- diagnose mode ----------------
if ($Diagnose) {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    "=== ОБЩЕЕ ==="
    "Версия MG Helper: $(Get-PkgVersion)"
    "Папка пакета:     $HelperDir"
    "Эталон:           $Golden (есть: $(Test-Path -LiteralPath $Golden))"
    $cfg = Get-MgConfig
    $sx = $cfg.settingsXml
    if (-not $sx -or -not (Test-Path -LiteralPath $sx)) { $sx = Find-SettingsXml }
    "Настройки игры:   $sx"
    if ($Golden -and (Test-Path -LiteralPath $Golden)) {
        $g = Get-Content -LiteralPath $Golden -Raw
        "Эталон валиден:   $($g -match '<Settings>')   повреждён: $($g -match '\$\d')"
        "TextureQuality:   $(([regex]::Match($g, '<TextureQuality value=`"([^`"]+)`"')).Groups[1].Value)"
        "CityDensity:      $(([regex]::Match($g, '<CityDensity value=`"([^`"]+)`"')).Groups[1].Value)"
    }
    if ($sx) {
        "Только чтение:    $((Get-Item -LiteralPath $sx -ErrorAction SilentlyContinue).IsReadOnly)"
        "Блокировка Win:   $(Test-Path -LiteralPath "$sx`:Zone.Identifier" -ErrorAction SilentlyContinue)"
    }
    "--- ПРОЦЕССЫ (имя + командная строка) ---"
    $gProc = @(Find-MatchingProcess -Patterns $cfg.gameProcesses)
    "GTA5:             $([bool]$gProc)"
    $lProc = @(Find-MatchingProcess -Patterns $cfg.launcherProcesses)
    "Majestic:         $([bool]$lProc)"
    $mProc = @(Find-MatchingProcess -Patterns $cfg.mgProcesses)
    "MG:               $([bool]$mProc)"
    "--- MIAMI GRAPHICS ---"
    $mgDir = $cfg.miamiGraphicsDir
    if (-not $mgDir -or -not (Test-Path -LiteralPath $mgDir)) { $mgDir = Find-MiamiGraphicsDir }
    "Установлен:       $([bool]$mgDir)"
    if ($mgDir) {
        $ver = Join-Path $mgDir 'config\installed_version.txt'
        if (Test-Path -LiteralPath $ver) { "Версия MG:        $((Get-Content -LiteralPath $ver -Raw).Trim())" }
    }
    "--- MAJESTIC ---"
    "Конфиг Majestic:  $($cfg.majesticJson)"
    if ($cfg.majesticJson) {
        "Кэш Majestic:     $(Get-MajesticCachePath $cfg.majesticJson)"
        $gp = Get-MajesticGamePath $cfg.majesticJson
        if ($gp) { "Папка игры:       $gp" }
    }
    "--- ВЫВОДЫ (автоматические) ---"
    $concl = @()
    if (-not $sx) { $concl += "[ПРОБЛЕМА] settings.xml не найден на этом ПК - запусти GTA V один раз, затем 1-install." }
    if ($Golden -and (Test-Path -LiteralPath $Golden)) {
        $g = Get-Content -LiteralPath $Golden -Raw -ErrorAction SilentlyContinue
        if ($g -and (($g -notmatch '<Settings>') -or ($g -match '\$\d'))) {
            $concl += "[ПРОБЛЕМА] эталон settings.golden.xml повреждён - запусти [2] Reset settings."
        }
    }
    if ($sx -and ((Get-Item -LiteralPath $sx -ErrorAction SilentlyContinue).IsReadOnly)) {
        $concl += "[ПРОБЛЕМА] settings.xml только для чтения - watcher сам снимет атрибут при запуске игры."
    }
    if (-not $mgDir) { $concl += "[ИНФО] Miami Graphics не найден - графика MG не установлена." }
    $docsPin = Get-DocsPin
    if ($sx -and $docsPin -and ($sx -notlike "$docsPin*")) {
        $concl += "[ПРОБЛЕМА] Документы перемещены! Настройки игры ($sx) вне текущей папки Документы ($docsPin). Rockstar SDK ищет данные в Документах - верни папку на место или запусти Repair [8]."
    }
    $autostartOk = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue).GTASettingsWatcher
    $watchdogOk = (schtasks /Query /TN "MG_Helper_Watchdog" 2>&1 | Out-String) -match 'MG_Helper_Watchdog'
    if (-not $autostartOk) { $concl += "[ПРОБЛЕМА] автозапуск watcher'а удалён из реестра - запусти 1-install." }
    if (-not $watchdogOk) { $concl += "[ПРОБЛЕМА] watchdog-задача отсутствует - watcher не перезапустится после смерти." }
    $logAge = if (Test-Path -LiteralPath $LogFile) { ((Get-Date) - (Get-Item -LiteralPath $LogFile).LastWriteTime).TotalMinutes } else { 99999 }
    if ($logAge -gt 120) { $concl += "[ВНИМАНИЕ] watcher.log не обновлялся $([int]$logAge) минут - возможно, watcher не работает." }
    if ($concl.Count -eq 0) { $concl += "Всё в порядке - проблем не найдено." }
    $concl | ForEach-Object {
        if ($_ -match '^\[ПРОБЛЕМА\]') { Write-Host "  $_" -ForegroundColor Red }
        elseif ($_ -match '^\[ВНИМАНИЕ\]') { Write-Host "  $_" -ForegroundColor Yellow }
        else { Write-Host "  $_" -ForegroundColor Green }
    }
    "=== ПОСЛЕДНИЕ СОБЫТИЯ ==="
    Get-Content -LiteralPath $LogFile -Tail 8 -ErrorAction SilentlyContinue
    exit 0
}

# ---------------- single instance (Local mutex) ----------------
$mutex = $null
try { $mutex = New-Object System.Threading.Mutex($false, $MutexName) } catch { $mutex = $null }
$mutexOk = $false
try { $mutexOk = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $mutexOk = $true }   # abandoned mutex is ACQUIRED by this call
catch { $mutexOk = $false }
if (-not $mutexOk) { exit 0 }

# ---------------- cooperative stop event ----------------
$stopEvent = $null
try { $stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $StopEvent) } catch { $stopEvent = $null }
    try { $stopEvent.Reset() } catch {}   # stale-signalled event from a previous instance must not stop us

# ---------------- settings + golden ----------------
$cfg = Resolve-MgPaths -ForceFull
if (-not $cfg.settingsXml) {
    Log "[!] settings.xml not found - edit $ConfigFile or run GTA V once"
    exit 1
}
$SettingsXml = $cfg.settingsXml

# golden: migrate/create, self-heal chain
if (-not (Test-GoldenValid $Golden)) {
    $src = Get-ValidGolden -CfgSettingsXml $SettingsXml
    if ($src) {
        New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
        Copy-Item -LiteralPath $src.path $Golden -Force
        Log "golden healed from $($src.path)"
    } else {
        Log "[!] no valid golden source - exiting"
        exit 1
    }
}

# ---------------- state machine (persistent) ----------------
$state = @{ schema = 1; phase = 'Idle'; gamePid = $null; sessionId = $null }
$stateFile = Join-Path $HelperDir 'state.json'
try {
    if (Test-Path -LiteralPath $stateFile) {
        $loaded = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($loaded.phase) { $state = @{ schema = 1; phase = $loaded.phase; gamePid = $loaded.gamePid } }
    }
} catch {}

# exit policy from config (adopt = user changes in game survive)
$onExit = 'adopt'
if ($cfg.onExit) { $onExit = [string]$cfg.onExit }

# self-heal autostart entry
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$expected = "`"$exe`" -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\gta-settings-watcher.ps1`""
$cur = (Get-ItemProperty $runKey -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue).GTASettingsWatcher
if ($cur -ne $expected) {
    New-ItemProperty $runKey -Name 'GTASettingsWatcher' -Value $expected -PropertyType String -Force | Out-Null
    Log "autostart entry re-added (self-heal)"
}

# unclean-shutdown detection: archived bins exist + nothing running
if (Ensure-BinsRestored -Cfg $cfg) {
    Log "[i] vanilla bins restored from archive (unclean previous session)"
}

Log "Watcher v6 started (onExit=$onExit, settings: $SettingsXml)"

$wasRunning = $false
if ($state.phase -eq 'InGame') {
    # previous watcher instance died mid-session: adopt without re-snapshot
    $gp = Get-Process -Id $state.gamePid -ErrorAction SilentlyContinue
    if ($gp) { $wasRunning = $true; Log "[i] adopting InGame session (PID $($state.gamePid))" }
    else { $state.phase = 'Idle' }
}
$lastBeat = Get-Date
$guardReapplies = 0

while ($true) {
    Start-Sleep -Seconds 5

    # cooperative stop
    try { if ($stopEvent -and $stopEvent.WaitOne(0)) { Log 'stop requested (event)'; break } } catch {}

    try {
        # re-discover settings.xml if it vanished
        if (-not (Test-Path -LiteralPath $cfg.settingsXml)) {
            $fresh = Resolve-MgPaths -NoSave
            if ($fresh -and $fresh.settingsXml) { $cfg = $fresh; $SettingsXml = $fresh.settingsXml }
        }
        if (-not $cfg.settingsXml) { continue }

        $running  = [bool](Find-MatchingProcess -Patterns $cfg.gameProcesses)
        $launcher = [bool](Find-MatchingProcess -Patterns $cfg.launcherProcesses)

        if ($running -and -not $wasRunning) {
            Snapshot-MgFiles -Cfg $cfg
            if ((Get-Item -LiteralPath $cfg.settingsXml -ErrorAction SilentlyContinue).IsReadOnly) {
                Set-ItemProperty -LiteralPath $cfg.settingsXml -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                Log "settings.xml was read-only - attribute cleared"
            }
            Copy-Item -LiteralPath $cfg.settingsXml (Join-Path $HelperDir 'settings.before_apply.bak') -Force
            Ensure-BinsRestored -Cfg $cfg
            if (Apply-Golden -Cfg $cfg) { Log "GTA5 launched -> settings applied" }
            if ($cfg.autoCleanDlccache) { Clean-Dlccache -Cfg $cfg }
            $state.phase = 'InGame'
            $state.gamePid = (@(Find-MatchingProcess -Patterns $cfg.gameProcesses) | Select-Object -First 1).Id
            Save-State $state $stateFile
            Start-Sleep -Seconds 3
            # one safety re-apply if overwritten right after launch
            if ((Find-MatchingProcess -Patterns $cfg.gameProcesses) -and -not ((Get-Content -LiteralPath $cfg.settingsXml -Raw) -ceq (Get-Content -LiteralPath $Golden -Raw))) {
                if (Apply-Golden -Cfg $cfg) { Log "settings re-applied (was overwritten after launch)" }
            }
        }
        elseif (-not $running -and $wasRunning) {
            Start-Sleep -Seconds 3
            if ($onExit -eq 'adopt' -and (Test-ValidSettingsXml $cfg.settingsXml)) {
                # adopt: user's in-game changes survive (default policy)
                $sRaw = [IO.File]::ReadAllText($cfg.settingsXml)
                $gRaw = [IO.File]::ReadAllText($Golden)
                if (($sRaw -replace '\r?\n', '') -ne ($gRaw -replace '\r?\n', '')) {
                    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
                    Copy-Item -LiteralPath $Golden (Join-Path $HelperDir "settings.golden.xml.old_$stamp") -Force
                    Copy-Item -LiteralPath $cfg.settingsXml $Golden -Force
                    Log "exit: settings changed in game - adopted as new golden"
                } else {
                    Log "GTA5 closed -> settings unchanged, golden kept"
                }
            } else {
                if (Apply-Golden -Cfg $cfg) { Log "GTA5 closed -> settings restored" }
            }
            Restore-VanillaBackup -Cfg $cfg
            $state.phase = 'Idle'
            $state.gamePid = $null
            Save-State $state $stateFile
        }
        $wasRunning = $running

        # heartbeat every 30 min
        if (((Get-Date) - $lastBeat).TotalMinutes -ge 30) {
            Log "heartbeat: alive (phase: $($state.phase), settings: $($cfg.settingsXml))"
            $lastBeat = Get-Date
        }
    } catch {
        Log "[!] Error: $_"
    }
}

