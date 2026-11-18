# ============================================================
#  MG Helper - installer (v5: universal - works on ANY Windows PC)
#  by Bayra & Kavel1n
#
#  Run ONCE. It sets up:
#  - golden settings = THIS PC owner's own settings.xml
#  - at every GTA V launch: snapshots MG files (archive only),
#    archives Majestic's vanilla backup so MG graphics survives,
#    applies golden, archives dlccache
#  - on game exit: restores settings and Majestic's files
#  - autostart of the watcher with Windows (self-healing)
#  - watcher has a -Diagnose mode for remote troubleshooting
#
#  v5 = UNIVERSAL: no hardcoded paths. settings.xml, MiamiGraphics
#  and Majestic are DISCOVERED on THIS PC (Documents / OneDrive /
#  any profile location / registry KFM). The result is cached in
#  %LOCALAPPDATA%\MG_Helper\config.json - edit that file to
#  override any path manually. Processes are matched by name AND
#  command line (covers renamed launchers).
# ============================================================

$host.UI.RawUI.WindowTitle = 'MG Helper - by Bayra & Kavel1n'
$ErrorActionPreference = 'Continue'

# remove Mark-of-the-Web from package files (archives sent via messengers get flagged)
Get-ChildItem $PSScriptRoot -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ------------------------------------------------------------
# 0. universal discovery module (ships with the package)
# ------------------------------------------------------------
$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    Write-Host "[!] common.ps1 missing next to this installer." -ForegroundColor Red
    Write-Host "    Re-download the whole package - it is required." -ForegroundColor DarkGray
    pause; exit 1
}
. $commonPath

$Settings = Find-SettingsXml
if (-not $Settings) {
    Write-Host "[!] Could not find Rockstar Games\GTA V\settings.xml on this PC." -ForegroundColor Red
    Write-Host "    Run GTA V once (so it creates its settings), then run this installer again." -ForegroundColor DarkGray
    pause; exit 1
}
$GtaDir = Split-Path $Settings
Write-Host "[i] GTA V settings found: $Settings"

# ------------------------------------------------------------
# 1. helper folder (always writable - the core of the "any PC" design)
# ------------------------------------------------------------
$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
try {
    New-Item -ItemType Directory -Force -Path $HelperDir -ErrorAction Stop | Out-Null
} catch {
    Write-Host "[!] Could not create helper folder: $HelperDir" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    pause; exit 1
}
if (-not (Test-Path $HelperDir)) {
    Write-Host "[!] Helper folder still missing: $HelperDir" -ForegroundColor Red
    pause; exit 1
}
Write-Host "[i] Helper folder: $HelperDir"

# migrate old golden/log from legacy Documents\_settings_backup if present
$legacyBackup = Join-Path (Split-Path $Settings) '_settings_backup'
$legacyGolden = Join-Path $legacyBackup 'settings.golden.xml'
$golden = Join-Path $HelperDir 'settings.golden.xml'
if (-not (Test-Path $golden) -and (Test-Path $legacyGolden)) {
    Copy-Item $legacyGolden $golden -Force
    Write-Host "[i] Migrated existing golden from legacy location." -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# 2. watcher script (v5: universal discovery + config + self-heal)
# ------------------------------------------------------------
$watcherCode = @'
param([switch]$Diagnose)
# MG Helper watcher v5 - universal - by Bayra & Kavel1n
# Golden settings are applied at every GTA5 launch and restored on exit.
# MG files are snapshotted (archive only). Majestic's vanilla backup is
# archived during the session so MG graphics survives, and returned after.
# Nothing is ever deleted. All package data lives in %LOCALAPPDATA%\MG_Helper.
# Paths are DISCOVERED (Documents / OneDrive / registry KFM / profile walk)
# and cached in config.json - edit that file to override manually.
# Processes are matched by name AND command line (renamed launchers work).

$ErrorActionPreference = 'SilentlyContinue'
$HelperDir  = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden     = Join-Path $HelperDir 'settings.golden.xml'
$LogFile    = Join-Path $HelperDir 'watcher.log'
$ConfigFile = Join-Path $HelperDir 'config.json'

# shared discovery module (deployed by 1-install.bat next to this script)
$common = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $common)) { $common = Join-Path $HelperDir 'common.ps1' }
if (Test-Path -LiteralPath $common) {
    . $common
} else {
    # degraded mode - bare fallbacks so the watcher can still log clearly
    function Get-MgConfig { return $null }
    function Resolve-MgPaths { return $null }
    function Find-MatchingProcess { param([string[]]$Patterns) return @() }
    function Find-SettingsXml { return $null }
    function Find-MiamiGraphicsDir { return $null }
    function Find-MajesticJson { return $null }
    function Get-MajesticCachePath { param($j) return $null }
}

function Log($msg) {
    # rotate: keep one .old generation when the log grows past 1 MB
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
            Move-Item $LogFile "$LogFile.old" -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Out-File $LogFile -Append -Encoding UTF8
}

function Get-MgDirs {
    param($Cfg)
    $dirs = @()
    if ($Cfg -and $Cfg.miamiGraphicsDir -and (Test-Path -LiteralPath $Cfg.miamiGraphicsDir)) { $dirs += $Cfg.miamiGraphicsDir }
    foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
        if (-not $root) { continue }
        $c = Join-Path $root 'MiamiGraphics'
        if ((Test-Path -LiteralPath $c) -and ($dirs -notcontains $c)) { $dirs += $c }
    }
    return ,$dirs
}

function Snapshot-Mg {
    # saves a full copy of MG settings files (nothing is ever deleted)
    param($MgDirs)
    try {
        if (-not $MgDirs -or @($MgDirs).Count -eq 0) { Log "[i] MG dirs not found - snapshot skipped"; return }
        $snapDir = Join-Path $HelperDir 'mg_snapshot'
        New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
        $n = 0
        foreach ($dir in $MgDirs) {
            if (-not (Test-Path $dir)) { continue }
            $root = ($dir -replace '[:\\/]', '_')
            foreach ($f in (Get-ChildItem $dir -Recurse -Depth 2 -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $rel = ($root + '__' + $f.FullName.Substring($dir.Length).TrimStart('\')) -replace '[\\/]', '__'
                Copy-Item $f.FullName (Join-Path $snapDir $rel) -Force
                $n++
            }
        }
        if ($n -gt 0) { Log "MG snapshot saved ($n files -> $snapDir)" }
    } catch {
        Log "[!] MG snapshot error: $_"
    }
}

function Get-MajesticBackupDir {
    param($Cfg)
    if ($Cfg -and $Cfg.majesticJson -and (Test-Path -LiteralPath $Cfg.majesticJson)) {
        $d = Join-Path (Split-Path $Cfg.majesticJson) 'backup'
        if (Test-Path -LiteralPath $d) { return $d }
    }
    $d = Join-Path $env:APPDATA 'majestic-launcher\Multiplayer\backup'
    if (Test-Path -LiteralPath $d) { return $d }
    return $null
}

function Clean-Dlccache {
    # archives dlccache .dat files into a backup folder instead of deleting
    param($Cfg)
    try {
        $cachePath = Get-MajesticCachePath $Cfg.majesticJson
        if (-not $cachePath) { $cachePath = Get-MajesticCachePath (Join-Path $env:APPDATA 'majestic-launcher\Multiplayer\majestic.json') }
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

function Archive-VanillaBackup {
    # archives Majestic's vanilla update.rpf backup (.bin) so MG graphics
    # survives the launch. Only ONE archived copy is kept (prune older).
    param($Cfg)
    try {
        $bkDir = Get-MajesticBackupDir $Cfg
        if (-not $bkDir) { return }
        $bins = Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue
        if (-not $bins) { return }
        $arcRoot = Join-Path $HelperDir 'vanilla_backup_archive'
        $arc = Join-Path $arcRoot (Get-Date -Format 'yyyy-MM-dd_HHmmss')
        New-Item -ItemType Directory -Force -Path $arc | Out-Null
        $bins | Move-Item -Destination $arc -Force -ErrorAction SilentlyContinue
        Get-ChildItem $arcRoot -Directory | Where-Object { $_.Name -ne (Split-Path $arc -Leaf) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Log ("vanilla backup archived {0} file(s) -> {1}" -f $bins.Count, $arc)
    } catch {
        Log "[!] vanilla backup archive error: $_"
    }
}

function Restore-VanillaBackup {
    # returns the archived vanilla backup back to Majestic ('before' state)
    param($Cfg)
    try {
        $bkDir = Get-MajesticBackupDir $Cfg
        if (-not $bkDir) { return }
        $latestArc = Get-ChildItem (Join-Path $HelperDir 'vanilla_backup_archive') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latestArc) { return }
        $files = Get-ChildItem $latestArc.FullName -Filter '*.bin' -ErrorAction SilentlyContinue
        if (-not $files) { return }
        $files | Move-Item -Destination $bkDir -Force -ErrorAction SilentlyContinue
        Log ("vanilla backup restored {0} file(s) from {1}" -f $files.Count, $latestArc.Name)
    } catch {
        Log "[!] vanilla backup restore error: $_"
    }
}

# ---------------- diagnose mode ----------------
if ($Diagnose) {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $cfg = Get-MgConfig

    "=== ОБЩЕЕ ==="
    "Версия MG Helper: $script:Version"
    "Папка пакета:    $HelperDir"
    "Эталон:          $Golden (есть: $(Test-Path $Golden))"
    "Конфиг:          $ConfigFile (есть: $(Test-Path $ConfigFile))"
    $sx = $cfg.settingsXml
    if (-not $sx -or -not (Test-Path -LiteralPath $sx)) { $sx = Find-SettingsXml }
    "Настройки игры:  $sx"
    if (-not $sx) { "  (не найдены! Настрой игру один раз или впиши путь в config.json)" }
    $g = Get-Content $Golden -Raw -ErrorAction SilentlyContinue
    if ($g) {
        "Эталон валиден:  $($g -match '<Settings>')   повреждён: $($g -match '\$\d')"
        "TextureQuality:  $(([regex]::Match($g, '<TextureQuality value=`"([^`"]+)`"')).Groups[1].Value)"
    } else {
        "Эталон:          нет или пуст (появится при первом запуске игры)"
    }
    if ($sx) {
        "Только чтение:   $((Get-Item $sx -ErrorAction SilentlyContinue).IsReadOnly)"
        "Блокировка Win:  $(Test-Path -LiteralPath "$sx`:Zone.Identifier" -ErrorAction SilentlyContinue)"
    }

    "=== ПРОЦЕССЫ (детект по имени + командной строке) ==="
    $gProc = @(Find-MatchingProcess -Patterns $cfg.gameProcesses)
    "GTA5:            $([bool]$gProc)  $(@($gProc | ForEach-Object { $_.Name }) -join ', ')"
    $lProc = @(Find-MatchingProcess -Patterns $cfg.launcherProcesses)
    "Majestic:        $([bool]$lProc)  $(@($lProc | ForEach-Object { $_.Name }) -join ', ')"
    $mProc = @(Find-MatchingProcess -Patterns $cfg.mgProcesses)
    "MG:              $([bool]$mProc)  $(@($mProc | ForEach-Object { $_.Name }) -join ', ')"

    "=== MIAMI GRAPHICS ==="
    $mgDir = $cfg.miamiGraphicsDir
    if (-not $mgDir -or -not (Test-Path -LiteralPath $mgDir)) { $mgDir = Find-MiamiGraphicsDir }
    "Установлен:      $([bool]$mgDir) ($(if ($mgDir) { $mgDir } else { 'папки не найдены' }))"
    if ($mgDir) {
        $ver = Join-Path $mgDir 'config\installed_version.txt'
        if (Test-Path $ver) { "Версия MG:       $((Get-Content $ver -Raw).Trim())" }
        foreach ($f in @('config\optimization_baseline.json','config\gta_settings_preset.json','config\optimization_mods.json')) {
            $p = Join-Path $mgDir $f
            if (Test-Path $p) { "Файл MG:         $p ($((Get-Item $p).Length) байт)" }
        }
        $optFile = Join-Path $mgDir 'config\optimization_mods.json'
        if (Test-Path $optFile) {
            $optRaw = (Get-Content $optFile -Raw -ErrorAction SilentlyContinue) -replace '\s',''
            if (-not $optRaw) { $optRaw = '(пусто)' }
            "Оптимизация MG:  $optRaw"
            if ($optRaw.Length -le 40) {
                "  (похоже, оптимизация выключена или не настроена:"
                "   MG -> 'Настройки графики GTA' -> включить оптимизацию и применить;"
                "   потом обязательно 2-reset-settings.bat, иначе watcher вернёт старый эталон)"
            }
        }
    }
    $snap = Join-Path $HelperDir 'mg_snapshot'
    if (Test-Path $snap) { "Снапшот MG:      $((Get-ChildItem $snap -File).Count) файлов (в $snap)" }
    else { "Снапшот MG:      ещё нет (появится при первом запуске GTA5)" }

    "=== MAJESTIC ==="
    $mjJson = $cfg.majesticJson
    if (-not $mjJson -or -not (Test-Path -LiteralPath $mjJson)) { $mjJson = Find-MajesticJson }
    "Конфиг Majestic: $(if ($mjJson) { $mjJson } else { 'не найден' })"
    if ($mjJson) {
        "Кэш Majestic:    $(Get-MajesticCachePath $mjJson)"
        $gamePath = Get-MajesticGamePath $mjJson
        if ($gamePath) { "Папка игры:     $gamePath" }
        $bkDir = Join-Path (Split-Path $mjJson) 'backup'
        if (Test-Path $bkDir) {
            $binCount = (Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue | Measure-Object).Count
            "Бэкап .bin в папке лаунчера: $binCount шт. (0 = архивированы, >0 = ждать запуска лаунчера)"
        }
    }

    "=== ВЕРСИЯ ИГРЫ ==="
    $game = Find-GtaGameRoot
    if ($game) { "GTA корень:      $($game.root)"; "Вариант:         $($game.variant)" }
    else { "GTA корень:      не определён по реестру (Steam/Epic/Rockstar ключи не найдены)" }

    "=== ВЫВОДЫ (автоматические) ==="
    $concl = @()
    if (-not $sx) {
        $concl += "[ПРОБЛЕМА] settings.xml не найден на этом ПК - запусти GTA V один раз, затем 1-install.bat."
    }
    if ($Golden -and (Test-Path $Golden)) {
        $gRaw = Get-Content $Golden -Raw -ErrorAction SilentlyContinue
        if ($gRaw -and (($gRaw -notmatch '<Settings>') -or ($gRaw -match '\$\d'))) {
            $concl += "[ПРОБЛЕМА] эталон settings.golden.xml повреждён - watcher применит его только после восстановления (запусти 2-reset-settings.bat)."
        }
    }
    if ($sx -and ((Get-Item $sx -ErrorAction SilentlyContinue).IsReadOnly)) {
        $concl += "[ПРОБЛЕМА] settings.xml только для чтения - watcher сам снимет атрибут при запуске игры."
    }
    if (-not $mgDir) {
        $concl += "[ИНФО] Miami Graphics не найден - графика MG не установлена (пакет защищает только базовые настройки)."
    }
    $optFile2 = if ($mgDir) { Join-Path $mgDir 'config\optimization_mods.json' } else { $null }
    if ($optFile2 -and (Test-Path $optFile2)) {
        $optRaw2 = ((Get-Content $optFile2 -Raw -ErrorAction SilentlyContinue) -replace '\s','')
        if ($optRaw2.Length -le 40) { $concl += "[ВНИМАНИЕ] оптимизация MG выключена или не настроена (optimization_mods.json почти пуст)." }
    }
    $watchProc = @(Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
    $autostartOk = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue).GTASettingsWatcher
    $watchdogOk = (schtasks /Query /TN "MG_Helper_Watchdog" 2>&1 | Out-String) -match 'MG_Helper_Watchdog'
    if (-not $autostartOk) { $concl += "[ПРОБЛЕМА] автозапуск watcher'а удалён из реестра - запусти 1-install.bat." }
    if (-not $watchdogOk) { $concl += "[ПРОБЛЕМА] watchdog-задача отсутствует - watcher не перезапустится после смерти." }
    $logAge = if (Test-Path $LogFile) { ((Get-Date) - (Get-Item $LogFile).LastWriteTime).TotalMinutes } else { 99999 }
    if ($logAge -gt 120) { $concl += "[ВНИМАНИЕ] watcher.log не обновлялся $([int]$logAge) минут - возможно, watcher не работает." }
    if ($concl.Count -eq 0) { $concl += "Всё в порядке - проблем не найдено." }
    $concl | ForEach-Object {
        if ($_ -match '^\[ПРОБЛЕМА\]') { Write-Host "  $_" -ForegroundColor Red }
        elseif ($_ -match '^\[ВНИМАНИЕ\]') { Write-Host "  $_" -ForegroundColor Yellow }
        else { Write-Host "  $_" -ForegroundColor Green }
    }

    "=== ПОДСКАЗКИ (если графика/оптимизация MG 'не работает') ==="
    " 1. Мод должен быть УСТАНОВЛЕН через лаунчер MG (каталог Redux),"
    "    а не просто скачан - иначе файлы игры не изменены."
    " 2. Оптимизация включается в MG отдельно ('Настройки графики GTA'),"
    "    отключена = файл optimization_mods.json размером ~17 байт."
    " 3. Если оптимизацию применили, но она 'слетает' к запуску игры:"
    "    watcher возвращает эталон settings.xml при каждом запуске GTA5."
    "    После ЛЮБОЙ смены графики (в игре или в MG) запусти 2-reset-settings.bat,"
    "    чтобы эталон обновился и не перезаписывал MG-настройки."
    " 4. Если что-то не нашлось автоматически: открой файл $ConfigFile"
    "    и впиши нужные пути вручную (settingsXml / miamiGraphicsDir / majesticJson)."

    "=== ПОСЛЕДНИЕ СОБЫТИЯ ==="
    Get-Content $LogFile -Tail 8 -ErrorAction SilentlyContinue
    exit 0
}

# ---------------- golden self-heal + atomic writes ----------------
function Test-GoldenValid {
    # golden must be a plausible settings.xml, never empty/truncated
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return ($raw.Length -gt 100 -and $raw -match '<Settings>' -and ($raw -notmatch '\$\d'))
    } catch { return $false }
}

function Get-ValidGolden {
    # returns the first VALID golden source: golden -> .bak -> before_apply.bak
    param([string]$CfgSettingsXml)
    $chain = @(
        $Golden,
        "$Golden.bak",
        (Join-Path $HelperDir 'settings.before_apply.bak'),
        $CfgSettingsXml
    )
    foreach ($c in ($chain | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-GoldenValid $c) { return @{ path = $c; healed = ($c -ne $Golden) } }
    }
    return $null
}

function Write-Atomic {
    # temp file + Replace, retry 3x on IOException (game holding the file open)
    param([string]$Path, [byte[]]$Bytes)
    $tmp = "$Path.mgtmp"
    for ($try = 1; $try -le 3; $try++) {
        try {
            [IO.File]::WriteAllBytes($tmp, $Bytes)
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $null) }
            else { Move-Item $tmp $Path -Force }
            return $true
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Log "[!] could not write $Path (locked?) - skipped"
    return $false
}

function Apply-Golden {
    # resolves a valid golden (self-heal chain) and atomically applies it
    param($Cfg)
    $src = Get-ValidGolden -CfgSettingsXml $Cfg.settingsXml
    if (-not $src) {
        Log "[!] no valid golden source found - nothing applied (golden NOT overwritten)"
        return $false
    }
    if ($src.healed) {
        Copy-Item $src.path $Golden -Force
        Log "[i] golden was corrupt - healed from $($src.path)"
    }
    $goldenBytes = [IO.File]::ReadAllBytes($Golden)
    if (Write-Atomic -Path $Cfg.settingsXml -Bytes $goldenBytes) {
        return $true
    }
    return $false
}

# ---------------- watcher runtime ----------------
# single-instance mutex (watchdog task may start extra instances - they exit here)
$mutex = New-Object System.Threading.Mutex($false, 'Global\MG_Helper_Watcher')
$mutexOk = $mutex.WaitOne(0)
if (-not $mutexOk) { exit 0 }

$cfg = Resolve-MgPaths
if ($cfg -and $cfg.settingsXml) {
    Log "Watcher v5.1 started (settings: $($cfg.settingsXml))"
} else {
    Log "[!] settings.xml not found - edit $ConfigFile to set it manually"
    exit 1
}

# unclean-shutdown detection: bins archived but nothing running since boot
$binsLeft = $null
$bkDir = Get-MajesticBackupDir $cfg
if ($bkDir) {
    $binsLeft = (Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue | Measure-Object).Count
}
$arcDir = Join-Path $HelperDir 'vanilla_backup_archive'
$archived = (Get-ChildItem $arcDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
if ((Test-Path $arcDir) -and $archived -gt 0 -and -not (Get-Process -Name 'GTA5' -ErrorAction SilentlyContinue)) {
    Log "[i] unclean previous session detected (archived bins not restored) - will restore on next exit"
}

if (-not (Test-Path $Golden)) {
    Copy-Item $cfg.settingsXml $Golden -Force
    Log "Created golden backup from $($cfg.settingsXml)"
}

# self-heal autostart (re-adds the entry if something removed it)
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$expected = "`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\gta-settings-watcher.ps1`""
$current = (Get-ItemProperty $runKey -Name 'GTASettingsWatcher' -ErrorAction SilentlyContinue).GTASettingsWatcher
if ($current -ne $expected) {
    New-ItemProperty $runKey -Name 'GTASettingsWatcher' -Value $expected -PropertyType String -Force | Out-Null
    Log "Autostart entry re-added (self-heal)"
}

$wasRunning = $false
$wasLauncher = $false
$errStreak = 0
$lastBeat = Get-Date

while ($true) {
    Start-Sleep -Seconds 5
    try {
        # re-discover if paths vanished (Documents/OneDrive relocation)
        if (-not $cfg.settingsXml -or -not (Test-Path -LiteralPath $cfg.settingsXml)) {
            $fresh = Resolve-MgPaths -NoSave
            if ($fresh -and $fresh.settingsXml) { $cfg = $fresh }
        }
        if (-not $cfg.settingsXml) { continue }

        $running  = [bool](Find-MatchingProcess -Patterns $cfg.gameProcesses)
        $launcher = [bool](Find-MatchingProcess -Patterns $cfg.launcherProcesses)

        if ($launcher -and -not $wasLauncher) {
            Log "Majestic launcher started"
            Archive-VanillaBackup -Cfg $cfg
        }
        $wasLauncher = $launcher

        if ($running -and -not $wasRunning) {
            Snapshot-Mg -MgDirs (Get-MgDirs $cfg)
            # clear read-only attribute if the user (or a tool) protected settings.xml
            if ((Get-Item $cfg.settingsXml -ErrorAction SilentlyContinue).IsReadOnly) {
                Set-ItemProperty $cfg.settingsXml -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                Log "settings.xml was read-only - attribute cleared"
            }
            Copy-Item $cfg.settingsXml (Join-Path $HelperDir 'settings.before_apply.bak') -Force
            if ($cfg.autoArchiveBins) { Archive-VanillaBackup -Cfg $cfg }   # opt-in: autoArchiveBins=true in config.json (can race with Majestic patcher -> error 1002)
            if (Apply-Golden -Cfg $cfg) { Log "GTA5 launched -> settings applied" }
            Clean-Dlccache -Cfg $cfg
            Start-Sleep -Seconds 3
            if ((Get-Process -Name $cfg.gameProcesses -ErrorAction SilentlyContinue) -and -not ((Get-Content $cfg.settingsXml -Raw) -ceq (Get-Content $Golden -Raw))) {
                if (Apply-Golden -Cfg $cfg) { Log "settings re-applied (was overwritten after launch)" }
            }
        }
        elseif (-not $running -and $wasRunning) {
            Start-Sleep -Seconds 3
            if (Apply-Golden -Cfg $cfg) { Log "GTA5 closed -> settings restored" }
            Restore-VanillaBackup -Cfg $cfg
        }
        $wasRunning = $running
        $errStreak = 0
        # heartbeat: one line per 30 min proves the watcher is alive even without events
        if (((Get-Date) - $lastBeat).TotalMinutes -ge 30) {
            Log "heartbeat: alive (settings: $($cfg.settingsXml))"
            $lastBeat = Get-Date
        }
    } catch {
        $errStreak++
        Log "[!] Error ($errStreak in a row): $_"
        # self-restart after repeated failures (clears corrupted state)
        if ($errStreak -ge 3) {
            Log "[!] 3 consecutive errors - restarting watcher"
            Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"" -WindowStyle Hidden
            exit 1
        }
    }
}
'@

# ------------------------------------------------------------
# 3. cache cleaner (manual, only truly destructive op, y/n prompt)
# ------------------------------------------------------------
$cleanCode = @'
# Cleans the whole Majestic asset cache (on demand). Universal discovery.
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Clean Cache'

$cachePath = $null
$cfgPath = Join-Path $env:LOCALAPPDATA 'MG_Helper\config.json'
$mjJson  = Join-Path $env:APPDATA 'majestic-launcher\Multiplayer\majestic.json'
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($cfg.majesticJson -and (Test-Path -LiteralPath $cfg.majesticJson)) { $mjJson = $cfg.majesticJson }
    } catch {}
}
if (Test-Path $mjJson) {
    try {
        $j = Get-Content $mjJson -Raw | ConvertFrom-Json
        foreach ($k in @('cachePath','cache','CachePath','cache_path')) {
            if ($j.$k) { $cachePath = ($j.$k -replace '"',''); break }
        }
    } catch {}
}
if (-not $cachePath -or -not (Test-Path $cachePath)) {
    Write-Host "[!] Majestic cache folder not found." -ForegroundColor Red
    Write-Host "    Check that Majestic was started at least once."
    pause; exit 1
}

if (Get-Process GTA5, 'Majestic Launcher' -ErrorAction SilentlyContinue) {
    Write-Host "[!] Majestic or GTA5 is running. Close them first!" -ForegroundColor Red
    pause; exit 1
}

$size = (Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Write-Host "============================================="
Write-Host " Majestic cache cleaner - by Bayra & Kavel1n"
Write-Host "============================================="
Write-Host ""
Write-Host ("Cache folder: $cachePath")
Write-Host ("Cache size:   {0:N0} MB" -f $size)
Write-Host ""
Write-Host "[!] WARNING: after cleaning, Majestic will re-download the whole cache on next launch." -ForegroundColor Yellow
Write-Host ""
$answer = Read-Host "Clean the cache now? (y/n)"
if ($answer -notin 'y','Y') { Write-Host "Cancelled."; pause; exit 0 }

Get-ChildItem $cachePath -Directory | ForEach-Object {
    Write-Host "Cleaning $($_.Name)..."
    Remove-Item "$($_.FullName)\*" -Recurse -Force -ErrorAction SilentlyContinue
}

$left = (Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Write-Host ("[+] Done. Remaining: {0:N0} MB" -f $left) -ForegroundColor Green
pause
'@

# ------------------------------------------------------------
# 4. uninstaller source lives in uninstall.ps1 (copied to MG_Helper in step 5)
# ------------------------------------------------------------

# ------------------------------------------------------------
# 5. deploy: common module + scripts, UTF-8 with BOM (PS 5.1)
#    Single source of truth: files next to this installer are
#    copied verbatim; only the watcher body is embedded above.
# ------------------------------------------------------------
$utf8bom = [Text.UTF8Encoding]::new($true)
foreach ($pair in @(
        @{ Src = 'common.ps1';                Dst = 'common.ps1' }
        @{ Src = 'clean-majestic-cache.ps1'; Dst = 'clean-majestic-cache.ps1' }
        @{ Src = 'uninstall.ps1';            Dst = 'uninstall-watcher.ps1' }
    )) {
    $srcFile = Join-Path $PSScriptRoot $pair.Src
    if (-not (Test-Path -LiteralPath $srcFile)) {
        Write-Host "[!] $($pair.Src) missing next to installer - re-download the package." -ForegroundColor Red
        pause; exit 1
    }
    Copy-Item $srcFile (Join-Path $HelperDir $pair.Dst) -Force
}
[IO.File]::WriteAllText((Join-Path $HelperDir 'gta-settings-watcher.ps1'), $watcherCode, $utf8bom)
# clean up legacy deployed scripts from pre-v4 installs
foreach ($old in @('apply-mg-preset.ps1','gta-settings-watcher.ps1','clean-majestic-cache.ps1','uninstall-watcher.ps1')) {
    Remove-Item (Join-Path $legacyBackup $old) -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# 6. golden backup (migrated above, or fresh from THIS PC's settings)
# ------------------------------------------------------------
if (-not (Test-Path $golden)) { Copy-Item $Settings $golden -Force }

# config.json: pin what the installer found (discovery writes the rest)
$cfg = Get-MgConfig
$cfg.settingsXml = $Settings
$mgFound = Find-MiamiGraphicsDir
if ($mgFound) { $cfg.miamiGraphicsDir = $mgFound }
$mjFound = Find-MajesticJson
if ($mjFound) { $cfg.majesticJson = $mjFound }
Save-MgConfig $cfg
Write-Host "[i] config.json written (discovered paths are cached there)." -ForegroundColor DarkGray

# ------------------------------------------------------------
# 7. autostart + run
# ------------------------------------------------------------
$watcherDst = Join-Path $HelperDir 'gta-settings-watcher.ps1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher|MG_Helper' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$runValue = "`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherDst`""
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "GTASettingsWatcher" -Value $runValue -PropertyType String -Force | Out-Null
Write-Host "[+] Added to Windows autostart." -ForegroundColor Green

# watchdog: every 10 minutes relaunch the watcher if it died (mutex prevents duplicates)
$watchdogTr = "`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherDst`""
schtasks /Create /F /SC MINUTE /MO 10 /TN "MG_Helper_Watchdog" /TR $watchdogTr | Out-Null
Write-Host "[+] Watchdog task added (relaunches the watcher every 10 min if it died)." -ForegroundColor Green

Start-Process powershell -ArgumentList '-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$watcherDst`"" -WindowStyle Hidden
Start-Sleep 4
if (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'gta-settings-watcher|MG_Helper' }) {
    Write-Host "[+] Watcher v5 is running." -ForegroundColor Green
    Write-Host ""
    Write-Host "Done! by Bayra & Kavel1n" -ForegroundColor Cyan
} else {
    Write-Host "[!] Watcher failed to start." -ForegroundColor Red
}
pause