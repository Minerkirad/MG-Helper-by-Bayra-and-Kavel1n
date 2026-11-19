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
        # manifest maps snapshot file -> original relative path. The legacy '__'
        # flattening is ambiguous if a folder/file name itself contains '__';
        # restore prefers the manifest and falls back to the legacy decode.
        $manifest = [ordered]@{}
        $n = 0
        foreach ($dir in $dirs) {
            $rootFlat = ($dir -replace '[:\\/]', '_')
            foreach ($f in (Get-ChildItem $dir -Recurse -Depth 2 -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $name = "$rootFlat`__f$n.json"
                $manifest[$name] = $f.FullName.Substring($dir.Length).TrimStart('\')
                Copy-Item -LiteralPath $f.FullName (Join-Path $snapDir $name) -Force
                $n++
            }
        }
        if ($n -gt 0) {
            [IO.File]::WriteAllText((Join-Path $snapDir 'manifest.json'), ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            Log "MG snapshot saved ($n files -> $snapDir)"
        }
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
if ((Ensure-BinsRestored -Cfg $cfg) -eq 'restored') {
    Log "[i] vanilla bins restored from archive (unclean previous session)"
}

Log "Watcher $(Get-PkgVersion) started (onExit=$onExit, guard=$sessionGuard window=${GuardWindowSec}s, settings: $SettingsXml)"

$wasRunning = $false
if ($state.phase -eq 'InGame') {
    # previous watcher instance died mid-session: adopt without re-snapshot
    $gp = Get-Process -Id $state.gamePid -ErrorAction SilentlyContinue
    if ($gp) { $wasRunning = $true; Log "[i] adopting InGame session (PID $($state.gamePid))" }
    else { $state.phase = 'Idle' }
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

        $running  = [bool](Find-MatchingProcess -Patterns $cfg.gameProcesses)
        $launcher = [bool](Find-MatchingProcess -Patterns $cfg.launcherProcesses)

        # 1002 insurance: bins must be vanilla BEFORE the launcher patches the game
        if ($launcher -and -not $script:wasLauncher) {
            Log "Majestic launcher started"
            if ((Ensure-BinsRestored -Cfg $cfg) -eq 'restored') { Log "vanilla bins restored before launcher patch" }
        }
        $script:wasLauncher = $launcher

        # if the previous loop iteration crashed on the exit branch, finish it now
        if (-not $running -and ($state.phase -eq 'InGame')) { $wasRunning = $true }

        if ($running -and -not $wasRunning) {
            Snapshot-MgFiles -Cfg $cfg
            if ((Get-Item -LiteralPath $cfg.settingsXml -ErrorAction SilentlyContinue).IsReadOnly) {
                Set-ItemProperty -LiteralPath $cfg.settingsXml -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                Log "settings.xml was read-only - attribute cleared"
            }
            Copy-Item -LiteralPath $cfg.settingsXml (Join-Path $HelperDir 'settings.before_apply.bak') -Force -ErrorAction SilentlyContinue
            Ensure-BinsRestored -Cfg $cfg | Out-Null
            $sessionStart = Get-Date
            $lastGuardReapply = [datetime]::MinValue
            $appliedThisSession = $false
            $lastApplyUtc = [datetime]::MinValue
            if (Apply-Golden -Cfg $cfg) {
                Log "GTA5 launched -> settings applied"
                $lastApplyUtc = Get-FileMtimeUtc $cfg.settingsXml
                $appliedThisSession = $true
            }
            if ($cfg.autoCleanDlccache) { Clean-Dlccache -Cfg $cfg }
            $state.phase = 'InGame'
            $state.gamePid = (@(Find-MatchingProcess -Patterns $cfg.gameProcesses) | Select-Object -First 1).Id
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
            $adopted = $false
            $same = Test-SameSettings $cfg.settingsXml $Golden          # $true / $false / $null
            $changedAfterUs = ((Get-FileMtimeUtc $cfg.settingsXml) -gt $lastApplyUtc.AddSeconds(2))
            if ((Test-AdoptCandidate $changedAfterUs ($onExit -eq 'adopt') $same $appliedThisSession) -and (Test-ValidSettingsXml $cfg.settingsXml)) {
                # adopt: the user's in-game changes become the new golden
                $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
                Copy-Item -LiteralPath $Golden (Join-Path $HelperDir "settings.golden.xml.old_$stamp") -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $cfg.settingsXml $Golden -Force -ErrorAction SilentlyContinue
                Log "exit: settings changed in game - adopted as new golden"
                $adopted = $true
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
            Restore-VanillaBackup -Cfg $cfg | Out-Null
            # build the 1002 insurance: copy (never move) launcher bins to the
            # archive now that the game is closed - safe from the patcher race
            if (Archive-VanillaBins -Cfg $cfg) { Log "vanilla bins archived (copy, insurance against error 1002)" }
            Prune-BackupFiles -Pattern 'settings.golden.xml.old_*'
            $state.phase = 'Idle'
            $state.gamePid = $null
            $state.sessionStart = $null
            $state.guardRollbacks = 0
            $state.applied = $false
            $state.lastApplyUtc = $null
            Save-State $state
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
