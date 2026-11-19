# MG Helper watcher - by Bayra & Kavel1n
# State machine (Idle/InGame, persistent), session drift-guard,
# adopt-on-exit policy, cooperative stop, log rotation, heartbeat.
# PS 5.1-safe. common.ps1 (dot-sourced) provides discovery/config/shared ops.
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
$TaskName   = 'MG_Helper_Watcher'

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
        # per-file LiteralPath: names with [ ] would break piped -Path resolution
        $files | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $arc -Force -ErrorAction SilentlyContinue }
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
        if (Test-Path -LiteralPath $StateFile) { [IO.File]::Replace($tmp, $StateFile, [NullString]::Value) }
        else { Move-Item -LiteralPath $tmp $StateFile -Force }
    } catch {
        try { Remove-Item -LiteralPath "$StateFile.tmp" -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# Test-SameSettings / Get-FileMtimeUtc / Test-GuardActive / Test-AdoptCandidate live in common.ps1

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
    }
    if (Test-Path -LiteralPath $StateFile) {
        "Состояние:        $((Get-Content -LiteralPath $StateFile -Raw -ErrorAction SilentlyContinue))"
    }
    "--- ПРОЦЕССЫ ---"
    "GTA5:             $([bool]@(Find-MatchingProcess -Patterns $cfg.gameProcesses))"
    "Majestic:         $([bool]@(Find-MatchingProcess -Patterns $cfg.launcherProcesses))"
    "MG:               $([bool]@(Find-MatchingProcess -Patterns $cfg.mgProcesses))"
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
        $bk = Get-MajesticBackupDir $cfg
        if ($bk) { "Бэкап .bin:       $(@(Get-ChildItem $bk -Filter '*.bin' -ErrorAction SilentlyContinue).Count) шт." }
    }
    "--- ВЫВОДЫ (автоматические) ---"
    $concl = @()
    if (-not $sx) { $concl += "[ПРОБЛЕМА] settings.xml не найден на этом ПК - запусти GTA V один раз, затем пункт меню [1]." }
    if ($Golden -and (Test-Path -LiteralPath $Golden)) {
        $g = Get-Content -LiteralPath $Golden -Raw -ErrorAction SilentlyContinue
        if ($g -and (($g -notmatch '<Settings>') -or ($g -match '\$\d'))) {
            $concl += "[ПРОБЛЕМА] эталон settings.golden.xml повреждён - запусти пункт меню [2] Reset settings."
        }
    }
    if ($sx -and ((Get-Item -LiteralPath $sx -ErrorAction SilentlyContinue).IsReadOnly)) {
        $concl += "[ПРОБЛЕМА] settings.xml только для чтения - watcher сам снимет атрибут при запуске игры."
    }
    if (-not $mgDir) { $concl += "[ИНФО] Miami Graphics не найден - защищаются только базовые настройки." }
    $docsPin = Get-DocsPin
    if ($sx -and $docsPin -and ($sx -notlike "$docsPin*")) {
        $concl += "[ПРОБЛЕМА] Документы перемещены! Настройки игры ($sx) вне текущей папки Документы ($docsPin). Rockstar SDK ищет данные в Документах - верни папку на место или запусти Repair [9]."
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { $concl += "[ПРОБЛЕМА] задача автозапуска MG_Helper_Watcher отсутствует - запусти пункт меню [9] Repair." }
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
try {
    $stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $StopEvent)
    $stopEvent.Reset()   # stale-signalled event from a previous instance must not stop us
} catch { $stopEvent = $null }

# ---------------- settings + golden ----------------
$cfg = Resolve-MgPaths -ForceFull
if (-not $cfg.settingsXml) {
    Log "[!] settings.xml not found - edit $ConfigFile or run GTA V once"
    exit 1
}
$SettingsXml = $cfg.settingsXml

# golden self-heal chain
if (-not (Test-GoldenValid $Golden)) {
    $src = Get-ValidGolden -CfgSettingsXml $SettingsXml
    if ($src) {
        New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
        Copy-Item -LiteralPath $src.path $Golden -Force
        if ($src.path -eq $SettingsXml) {
            Log "[!] golden healed from LIVE settings.xml - verify it is what you want to protect"
        } else {
            Log "golden healed from $($src.path)"
        }
    } else {
        Log "[!] no valid golden source - exiting"
        exit 1
    }
}

# ---------------- state machine (persistent) ----------------
$state = @{ schema = 2; phase = 'Idle'; gamePid = $null; sessionStart = $null; guardRollbacks = 0; restarts = 0
            applied = $false; lastApplyUtc = $null }   # additive fields, schema stays 2
$stateFile = $StateFile
try {
    if (Test-Path -LiteralPath $stateFile) {
        $loaded = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($loaded.phase) {
            # schema 1 had sessionReapplied - deliberately dropped: it silently killed adopt
            $state = @{ schema = 2; phase = $loaded.phase; gamePid = $loaded.gamePid
                        sessionStart = $loaded.sessionStart; guardRollbacks = [int]$loaded.guardRollbacks
                        restarts = [int]$loaded.restarts
                        applied = [bool]$loaded.applied; lastApplyUtc = $loaded.lastApplyUtc }
        }
    }
} catch {}

# exit policy from config (adopt = user changes in game survive)
$onExit = 'adopt'
if ($cfg.onExit) { $onExit = [string]$cfg.onExit }
# in-session drift-guard (config kill-switch)
$sessionGuard = $true
if ($null -ne $cfg.sessionGuard) { $sessionGuard = [bool]$cfg.sessionGuard }
# the guard is active ONLY this many seconds after the game starts: that is when
# Majestic/MG patch settings.xml. Anything written later is the user's own change
# and must survive until adopt-on-exit. 0 = guard off.
$GuardWindowSec = 120
if ($null -ne $cfg.guardWindowSec) { $GuardWindowSec = [int]$cfg.guardWindowSec }

# autostart: verify scheduled task exists (Run key is legacy - NOT recreated)
if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
    Log "[!] scheduled task MG_Helper_Watcher missing - run Repair (menu [9])"
}

# unclean-shutdown detection: archived bins exist + nothing running
$binsStatus = Ensure-BinsRestored -Cfg $cfg
if ($binsStatus -eq 'restored') {
    Log "[i] vanilla bins restored from archive (unclean previous session)"
}
elseif ($binsStatus -eq 'partial') {
    Log "[!] vanilla bins restored PARTIALLY - next tick continues; launcher patch may need a retry"
}
elseif ($binsStatus -eq 'failed') {
    Log "[!] vanilla bins could NOT be restored - Majestic may hit error 1002 this launch"
}

Log "Watcher $(Get-PkgVersion) started (onExit=$onExit, guard=$sessionGuard window=${GuardWindowSec}s, settings: $SettingsXml)"

# MG-CR-004: trust the state only if it is schema 2 with a known phase
$stateTrusted = $false
try {
    if ($state.schema -eq 2 -and $state.phase -in @('Idle', 'InGame')) { $stateTrusted = $true }
} catch { $stateTrusted = $false }

$wasRunning = $false
if ($state.phase -eq 'InGame') {
    # previous watcher instance died mid-session: adopt without re-snapshot.
    # PID reuse guard: the pid must still belong to a game-like process
    $gp = Get-Process -Id $state.gamePid -ErrorAction SilentlyContinue
    if ($gp -and ($gp.Name -like 'GTA5*' -or $gp.Name -like '*gtav*')) {
        $wasRunning = $true; Log "[i] adopting InGame session (PID $($state.gamePid))"
    } else { $state.phase = 'Idle' }
}
if (-not $wasRunning) {
    # game ALREADY running at watcher start: without a trusted InGame state we
    # must NOT apply the golden (would stomp the user's mid-game changes) and
    # must NOT adopt on exit (the file may contain launcher overwrites).
    # UnknownSession: observe only, wait for the game to close, then reset.
    $gameAlreadyRunning = @(Find-MatchingProcess -Patterns $cfg.gameProcesses).Count -gt 0
    if ($gameAlreadyRunning) {
        $state.phase = 'UnknownSession'
        $state.gamePid = $null
        $wasRunning = $true
        Save-State $state
        Log '[!] game already running and state is not trusted - SAFE MODE (no golden apply, no adopt) until the game closes'
    }
}
$lastBeat = Get-Date
$script:wasLauncher = $false
$errStreak = 0
$lastErrAt = Get-Date
$lastGuardReapply = [datetime]::MinValue
$lastApplyUtc = [datetime]::MinValue   # mtime of settings.xml right after OUR last write
$appliedThisSession = $false           # did WE successfully apply golden in THIS session?
$script:restartPending = $false
$sessionStart = $null
if ($state.sessionStart) { try { $sessionStart = [datetime]$state.sessionStart } catch { $sessionStart = $null } }
if ($wasRunning) {
    # takeover after a mid-session restart: restore the adopt evidence too,
    # otherwise the exit branch would see MinValue and could adopt foreign writes
    $appliedThisSession = [bool]$state.applied
    if ($state.lastApplyUtc) { try { $lastApplyUtc = [datetime]$state.lastApplyUtc } catch {} }
}

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

        $procs    = @(Find-MatchingProcess -Patterns $cfg.gameProcesses)
        $running  = [bool]$procs
        $launcher = [bool](Find-MatchingProcess -Patterns $cfg.launcherProcesses)

        # fast relaunch (crash + restart within one poll): a NEW pid means a NEW
        # session - without this, the old sessionStart/appliedThisSession survive
        # and the launcher's overwrite could be adopted as the user's choice
        $newPid = ($procs | Select-Object -First 1).Id
        if ($running -and $wasRunning -and ($state.phase -eq 'InGame') -and ($newPid -ne $state.gamePid)) {
            Log "[i] new game PID $newPid != $($state.gamePid) - treating as a new session"
            $wasRunning = $false   # the launch branch below re-initialises everything
        }

        # 1002 insurance: bins must be vanilla BEFORE the launcher patches the game
        if ($launcher -and -not $script:wasLauncher) {
            Log "Majestic launcher started"
            $bs = Ensure-BinsRestored -Cfg $cfg
            if ($bs -eq 'restored') { Log "vanilla bins restored before launcher patch" }
            elseif ($bs -in @('partial', 'failed')) { Log "[!] vanilla bins $bs before launcher patch - error 1002 risk this launch" }
        }
        $script:wasLauncher = $launcher

        # if the previous loop iteration crashed on the exit branch, finish it now
        if (-not $running -and ($state.phase -eq 'InGame')) { $wasRunning = $true }

        if ($running -and -not $wasRunning) {
            Snapshot-MgFiles -Cfg $cfg -Logger ${function:Log}
            if ((Get-Item -LiteralPath $cfg.settingsXml -ErrorAction SilentlyContinue).IsReadOnly) {
                Set-ItemProperty -LiteralPath $cfg.settingsXml -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                Log "settings.xml was read-only - attribute cleared"
            }
            # MG-CR-006: the pre-apply backup is CRITICAL - without it the user's
            # current settings could not be recovered if the golden were wrong.
            $preBackupOk = $false
            try {
                Copy-Item -LiteralPath $cfg.settingsXml (Join-Path $HelperDir 'settings.before_apply.bak') -Force -ErrorAction Stop
                $preBackupOk = $true
            } catch { Log "[!] pre-apply backup FAILED: $_ - golden will NOT be applied (nothing overwritten)" }
            Ensure-BinsRestored -Cfg $cfg | Out-Null
            $sessionStart = Get-Date
            $lastGuardReapply = [datetime]::MinValue
            $appliedThisSession = $false
            $lastApplyUtc = [datetime]::MinValue
            if ($preBackupOk -and (Apply-Golden -Cfg $cfg)) {
                Log "GTA5 launched -> settings applied"
                $lastApplyUtc = Get-FileMtimeUtc $cfg.settingsXml
                $appliedThisSession = $true
            }
            if ($cfg.autoCleanDlccache) { Clean-Dlccache -Cfg $cfg }
            $state.phase = 'InGame'
            $state.gamePid = $newPid
            $state.sessionStart = $sessionStart.ToString('o')
            $state.guardRollbacks = 0
            $state.applied = $appliedThisSession
            $state.lastApplyUtc = $lastApplyUtc.ToString('o')
            Save-State $state
            Start-Sleep -Seconds 3
            # one safety re-apply if overwritten right after launch ($null = unreadable -> skip)
            if ((Find-MatchingProcess -Patterns $cfg.gameProcesses) -and ((Test-SameSettings $cfg.settingsXml $Golden) -eq $false)) {
                if (Apply-Golden -Cfg $cfg) {
                    Log "settings re-applied (was overwritten after launch)"
                    $lastApplyUtc = Get-FileMtimeUtc $cfg.settingsXml
                    $appliedThisSession = $true
                    $state.applied = $true; $state.lastApplyUtc = $lastApplyUtc.ToString('o')
                    Save-State $state
                }
            }
        }
        elseif (-not $running -and $wasRunning) {
            Start-Sleep -Seconds 3
            if ($state.phase -eq 'UnknownSession') {
                # MG-CR-004: safe mode - no adopt, no restore, no golden writes.
                # The game that started before us is done; reset and observe fresh.
                Log "[i] unknown session ended - safe re-init (nothing was written)"
                Restore-VanillaBackup -Cfg $cfg | Out-Null
                $state.phase = 'Idle'
                $state.gamePid = $null
                $state.sessionStart = $null
                $state.guardRollbacks = 0
                $state.applied = $false
                $state.lastApplyUtc = $null
                Save-State $state
                $sessionStart = $null
            }
            else {
            $adopted = $false
            $same = Test-SameSettings $cfg.settingsXml $Golden          # $true / $false / $null
            $changedAfterUs = ((Get-FileMtimeUtc $cfg.settingsXml) -gt $lastApplyUtc.AddSeconds(2))
            if ((Test-AdoptCandidate $changedAfterUs ($onExit -eq 'adopt') $same $appliedThisSession) -and (Test-ValidSettingsXml $cfg.settingsXml)) {
                # adopt: the user's in-game changes become the new golden
                $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
                Copy-Item -LiteralPath $Golden (Join-Path $HelperDir "settings.golden.xml.old_$stamp") -Force -ErrorAction SilentlyContinue
                # atomic: a crash mid-copy must not leave a torn golden
                $adoptBytes = [IO.File]::ReadAllBytes($cfg.settingsXml)
                if (-not (Write-Atomic -Path $Golden -Bytes $adoptBytes)) {
                    Log "[!] could not write golden (locked?) - golden kept"
                } else {
                    Log "exit: settings changed in game - adopted as new golden"
                    $adopted = $true
                }
            }
            elseif ($null -eq $same) { Log "[i] exit: settings.xml unreadable - golden kept, adopt skipped" }
            elseif ($same) { Log "GTA5 closed -> settings unchanged, golden kept" }
            elseif (-not $appliedThisSession) { Log "GTA5 closed -> golden never applied this session - adopt skipped (foreign overwrite?)" }
            elseif (-not $changedAfterUs) { Log "GTA5 closed -> nobody wrote after our apply - golden kept" }
            else { Log "GTA5 closed -> onExit=$onExit - user changes not adopted" }
            if (-not $adopted -and ($same -eq $false)) {
                if (Apply-Golden -Cfg $cfg) {
                    Log "GTA5 closed -> golden restored"
                    $lastApplyUtc = Get-FileMtimeUtc $cfg.settingsXml
                }
            }
            }
            # shared exit tail: bins bookkeeping is safe in both modes
            Restore-VanillaBackup -Cfg $cfg | Out-Null
            # build the 1002 insurance: copy (never move) launcher bins to the
            # archive now that the game is closed - safe from the patcher race
            if (Archive-VanillaBins -Cfg $cfg) { Log "vanilla bins archived (copy, insurance against error 1002)" }
            Prune-BackupFiles -Pattern 'settings.golden.xml.old_*'
            if ($state.phase -ne 'UnknownSession') {
                $state.phase = 'Idle'
                $state.gamePid = $null
                $state.sessionStart = $null
                $state.guardRollbacks = 0
                $state.applied = $false
                $state.lastApplyUtc = $null
                Save-State $state
            }
            $sessionStart = $null
            # deferred self-restart: safe now that the game is closed
            if ($script:restartPending) {
                $script:restartPending = $false
                Log "deferred restart now (game closed)"
                try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {}
                $hostExe = Join-Path $HelperDir 'MG-Helper-Host.exe'
                if (Test-Path -LiteralPath $hostExe) {
                    Start-Process $hostExe -ArgumentList "`"$PSCommandPath`""
                } else {
                    Start-Process powershell -ArgumentList '-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"" -WindowStyle Hidden
                }
                exit 1
            }
        }
        # drift-guard: ONLY inside the launch window (Test-GuardActive).
        # Rollbacks here are foreign overwrites by Majestic/MG - they must NOT
        # disable adopt-on-exit: the user's own later changes are legitimate.
        if ((Test-GuardActive $sessionStart $GuardWindowSec $sessionGuard $running) -and
            ((Get-Date) - $lastGuardReapply).TotalSeconds -ge 10) {
            $same = Test-SameSettings $cfg.settingsXml $Golden
            if ($same -eq $false) {
                if (Apply-Golden -Cfg $cfg) {
                    Log "session guard: foreign overwrite in launch window - golden re-applied"
                    $lastApplyUtc = Get-FileMtimeUtc $cfg.settingsXml
                    $appliedThisSession = $true
                    $state.applied = $true
                    $state.lastApplyUtc = $lastApplyUtc.ToString('o')
                    $state.guardRollbacks = [int]$state.guardRollbacks + 1
                    Save-State $state
                }
            }
            # equal or unreadable (game holds the file) -> back off, do not hammer the disk
            $lastGuardReapply = Get-Date
        }

        $errStreak = 0

        # heartbeat every 30 min
        if (((Get-Date) - $lastBeat).TotalMinutes -ge 30) {
            Log "heartbeat: alive (phase: $($state.phase), settings: $($cfg.settingsXml), guardRollbacks: $([int]$state.guardRollbacks))"
            $lastBeat = Get-Date
            if (([int]$state.restarts -gt 0) -and ((Get-Date) - $lastErrAt).TotalMinutes -ge 30) {
                $state.restarts = 0; Save-State $state   # healthy 30 min - reset the restart budget
            }
        }
    } catch {
        $errStreak++
        $lastErrAt = Get-Date
        Log "[!] Error ($errStreak in a row): $_"
        if ($errStreak -ge 3) {
            # during a game session do NOT respawn: any spawn may steal focus and
            # minimise a fullscreen game - defer until the exit branch runs
            if (Find-MatchingProcess -Patterns $cfg.gameProcesses) {
                Log "[!] errors during game session - restart deferred until exit"
                $script:restartPending = $true
                $errStreak = 0
            } else {
                $restarts = [int]$state.restarts + 1
                $state.restarts = $restarts
                Save-State $state
                if ($restarts -gt 5) {
                    Log "[!] self-restart budget exhausted - exiting, scheduled task will retry within 10 min"
                    $state.restarts = 0
                    Save-State $state
                    exit 1
                }
                $delay = [int][Math]::Min(300, 30 * [Math]::Pow(2, $restarts - 1))
                Log "[!] 3 consecutive errors - self-restart #$restarts in $delay s"
                Start-Sleep -Seconds $delay
                # release the single-instance mutex BEFORE spawning the child, otherwise
                # the child loses WaitOne(0) against us and dies immediately
                try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {}
                # the hidden host spawns PowerShell with CreateNoWindow - no console flash
                $hostExe = Join-Path $HelperDir 'MG-Helper-Host.exe'
                if (Test-Path -LiteralPath $hostExe) {
                    Start-Process $hostExe -ArgumentList "`"$PSCommandPath`""
                } else {
                    Start-Process powershell -ArgumentList '-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"" -WindowStyle Hidden
                }
                exit 1
            }
        }
    } finally {
        # the state invariant must hold even if a branch threw half-way through
        if ($null -ne $running) { $wasRunning = $running }
    }
}

Log "watcher stopped"
# Snapshot-MgFiles lives in common.ps1 (Logger-aware, unit-tested by tools/check.ps1)

