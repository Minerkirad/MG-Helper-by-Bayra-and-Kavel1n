# ============================================================
#  MG Helper - common.ps1 (universal discovery + config + shared ops)
#  by Bayra & Kavel1n
#
#  Dot-sourced by the watcher, menu, repair and helper tools.
#  Everything here is PS 5.1-safe. The FILE must be UTF-8 with BOM.
# ============================================================

$script:Version = '2.6.1'   # держать в синке с version.json
$script:RepoSlug = 'Minerkirad/MG-Helper-by-Bayra-and-Kavel1n'
# MG3-021 (3.0, план docs/PLAN-3.0.md этап 1): тестовый хук. По умолчанию - живая
# папка; MG_HELPER_DIR направляет ВСЁ состояние в песочницу, чтобы настоящий цикл
# watcher'а можно было прогнать тестом (tools\integration.ps1), не трогая установку.
$script:HelperDir = if ($env:MG_HELPER_DIR) { [IO.Path]::GetFullPath($env:MG_HELPER_DIR) } else { Join-Path $env:LOCALAPPDATA 'MG_Helper' }
$script:ConfigFile = Join-Path $script:HelperDir 'config.json'
$script:VersionFile = Join-Path $PSScriptRoot 'version.json'

# 3.0 (этап 3): чистые решения живут в MgHelper.Core.ps1 - один источник правды
# для PS-реализации и будущего C#-ядра (docs/adr/ADR-001). Dot-source, а не
# Import-Module: файл деплоится рядом, модульное состояние не нужно.
$script:CoreModule = Join-Path $PSScriptRoot 'MgHelper.Core.ps1'
if (Test-Path -LiteralPath $script:CoreModule) {
    . $script:CoreModule
} else {
    Write-Warning 'MG Helper: MgHelper.Core.ps1 отсутствует рядом с common.ps1 - переустанови пакет (меню [1])'
}

# ------------------------------------------------------------
# version: version.json is the single source of truth,
# fallback to the hardcoded value if the file is missing/broken
# ------------------------------------------------------------
function Get-PkgVersion {
    try {
        $vf = Join-Path $PSScriptRoot 'version.json'
        if (Test-Path -LiteralPath $vf) {
            $v = (Get-Content -LiteralPath $vf -Raw -ErrorAction Stop | ConvertFrom-Json).version
            if ($v) { return [string]$v }
        }
    } catch {}
    return $script:Version
}

# ------------------------------------------------------------
# config load/save (JSON, atomic replace, broken-config backup)
# ------------------------------------------------------------
function Get-MgConfig {
    $cfg = [ordered]@{
        version           = 1
        # политика 2.6.1: политика версионируется отдельно, чтобы миграция
        # (onExit=adopt и guardWindowSec=120 от старых установок) выполнилась один раз.
        # 3 - после починки гейта: первый билд 2.6.1 писал cfgVersion=2, не применив
        # миграцию, поэтому такие конфиги лечатся отдельной веткой.
        cfgVersion        = 3
        settingsXml       = ''
        miamiGraphicsDir  = ''
        majesticJson      = ''
        lastFullDiscovery = ''
        gameProcesses     = @('GTA5', 'GTA5_Enhanced')
        launcherProcesses = @('Majestic', 'MajesticLauncher', 'majestic-launcher')
        mgProcesses       = @('Miami', 'MiamiGraphics')
        autoCleanDlccache = $false
        autoUpdate        = $false
        # deprecated: больше НЕ включает adopt (см. allowAdopt). Оставлен для совместимости.
        onExit            = 'restore'
        # opt-in: правки на диске при выходе становятся новым эталоном.
        # По умолчанию выключено - эталон при выходе восстанавливается, как в 1.x.
        allowAdopt        = $false
        sessionGuard      = $true
        # 0 = охранять ВСЮ сессию (чужую перезапись откатывать в любой момент);
        # >0 = только первые N секунд (старое поведение)
        guardWindowSec    = 0
        docsRoot          = (Get-DocsPin)
    }
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $loaded = Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in @($cfg.Keys)) {
                if ($null -ne $loaded.$p) { $cfg[$p] = $loaded.$p }
            }
            # старый конфиг без cfgVersion: дефолт (3) замаскировал бы отсутствие
            # ключа, и миграция политики не выполнилась бы никогда
            if ($null -eq $loaded.cfgVersion) { $cfg.cfgVersion = 0 }
        } catch {
            # config exists but is broken - keep a copy for the user, use defaults
            try {
                $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
                Copy-Item -LiteralPath $script:ConfigFile (Join-Path $script:HelperDir "config.json.broken_$stamp.bak") -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }
    return $cfg
}

function Save-MgConfig {
    # MG-CR-001: never destroys the existing config on failure. Non-destructive
    # flow: write tmp -> validate it parses -> atomic replace. On ANY failure the
    # old config stays untouched, the tmp is cleaned, $false is returned.
    param($Config)
    $tmp = $null
    try {
        New-Item -ItemType Directory -Force -Path $script:HelperDir -ErrorAction Stop | Out-Null
        $json = $Config | ConvertTo-Json -Depth 4
        $tmp = "$script:ConfigFile.$PID.tmp"
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        # the tmp must be readable JSON before we touch the real config
        $null = Get-Content -LiteralPath $tmp -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (Test-Path -LiteralPath $script:ConfigFile) {
            [IO.File]::Replace($tmp, $script:ConfigFile, [NullString]::Value)
        }
        else {
            [IO.File]::Move($tmp, $script:ConfigFile)
        }
        return $true
    }
    catch {
        Write-Warning "MG Helper: config save failed: $_"
        return $false
    }
    finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


# ------------------------------------------------------------
# known user Documents roots (KFM-redirection aware)
# ------------------------------------------------------------
function Get-DocsRoots {
    $roots = @()
    try   { $roots += [Environment]::GetFolderPath('MyDocuments') } catch {}
    try   { $roots += "$env:USERPROFILE\OneDrive\Documents" } catch {}
    try   { $roots += "$env:USERPROFILE\OneDrive\Документы" } catch {}
    try   { $roots += "$env:USERPROFILE\Documents" } catch {}
    try {
        $personal = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name Personal -ErrorAction Stop).Personal
        if ($personal) {
            $expanded = [Environment]::ExpandEnvironmentVariables($personal)
            if ($expanded -match '^(?:[A-Za-z]:|\\\\)') { $roots += $expanded }
        }
    } catch {}
    foreach ($one in (Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
        $roots += $one.FullName
        $roots += (Join-Path $one.FullName 'Documents')
        $roots += (Join-Path $one.FullName 'Документы')
    }
    return ($roots | Where-Object { $_ } | Select-Object -Unique)
}

# ------------------------------------------------------------
# GTA install discovery via registry (Steam / Epic / Rockstar)
# Returns @{ root; variant = 'GTA V' | 'GTA V Enhanced' } or $null
# ------------------------------------------------------------
function Find-GtaGameRoot {
    $roots = @()
    try {
        $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        $libs = @($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in ([regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"'))) {
                $libs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
        foreach ($lib in ($libs | Select-Object -Unique)) {
            foreach ($tail in @('steamapps\common\Grand Theft Auto V', 'steamapps\common\Grand Theft Auto V Enhanced')) {
                $roots += (Join-Path $lib $tail)
            }
        }
    } catch {}
    foreach ($r in @("$env:ProgramData\Epic\EpicGamesLauncher", "$env:ProgramFiles\Epic Games")) {
        if (Test-Path -LiteralPath $r) { $roots += $r }
    }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        try {
            foreach ($k in (Get-ChildItem $key -ErrorAction SilentlyContinue)) {
                $dn = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).DisplayName
                if ($dn -match 'Grand Theft Auto V') {
                    $loc = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).InstallLocation
                    if ($loc -and (Test-Path -LiteralPath $loc)) { $roots += $loc }
                }
            }
        } catch {}
    }
    foreach ($r in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $variant = if ($r -match 'Enhanced') { 'GTA V Enhanced' } else { 'GTA V' }
        if (Test-Path -LiteralPath (Join-Path $r 'GTA5.exe')) {
            return @{ root = $r; variant = $variant }
        }
    }
    return $null
}



# ------------------------------------------------------------
# settings.xml validation + discovery
# (tail order is variant-aware via Find-GtaGameRoot)
# ------------------------------------------------------------
function Test-ValidSettingsXml {
    # MG-CR-003: real XML validation (well-formed document + <Settings> root),
    # not just a text grep - a torn/partial file must never become the golden.
    # DTD is prohibited and the resolver is null (no external entities).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    # path-based exclusions live in the DISCOVERY code (Find-SettingsXml) -
    # golden backups legitimately live inside MG_Helper, so this validator is
    # pure CONTENT validation
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($Path, $settings)
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.Load($reader)
            return ($doc.DocumentElement -and $doc.DocumentElement.Name -eq 'Settings')
        }
        finally { $reader.Dispose() }
    } catch { return $false }
}

function Find-SettingsXml {
    param([switch]$NoWalk)
    $tails = @('Rockstar Games\GTA V\settings.xml', 'Rockstar Games\GTA V Enhanced\settings.xml')
    $game = Find-GtaGameRoot
    if ($game -and $game.variant -eq 'GTA V Enhanced') {
        $tails = @('Rockstar Games\GTA V Enhanced\settings.xml', 'Rockstar Games\GTA V\settings.xml')
    }
    foreach ($d in (Get-DocsRoots)) {
        foreach ($tail in $tails) {
            $c = Join-Path $d $tail
            # standard docs root: trusted by construction (existence-only check -
            # the game may hold settings.xml with exclusive access while running)
            if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
        }
    }
    if ($NoWalk) { return $null }
    $cands = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 6 -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'GTA\s*V|Rockstar' -and $_.FullName -notmatch '\\Temp\\|\\AppData\\|_settings_backup|MG_Helper' }
    foreach ($c in $cands) {
        $f = Join-Path $c.FullName 'settings.xml'
        if ((Test-Path -LiteralPath $f -PathType Leaf) -and (Test-ValidSettingsXml $f)) { return $f }
    }
    return $null
}

# ------------------------------------------------------------
# MiamiGraphics discovery, content-validated
# ------------------------------------------------------------
function Test-ValidMgDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($probe in @('config\installed_version.txt', 'config\gpu.json', 'install_state.json',
                         'optimization_baseline.json', 'gta_settings_preset.json', 'config\optimization_mods.json')) {
        if (Test-Path -LiteralPath (Join-Path $Path $probe)) { return $true }
    }
    return $false
}

function Find-MiamiGraphicsDir {
    foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
        $c = Join-Path $root 'MiamiGraphics'
        if (Test-ValidMgDir $c) { return $c }
    }
    $cands = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 4 -Directory -Filter 'MiamiGraphics' -ErrorAction SilentlyContinue
    foreach ($c in $cands) {
        if (Test-ValidMgDir $c.FullName) { return $c.FullName }
    }
    return $null
}

# ------------------------------------------------------------
# Majestic config discovery, content-validated
# ------------------------------------------------------------
function Test-ValidMajesticJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($k in @('cachePath', 'gamePath', 'installPath', 'gtaPath', 'name', 'gtapath')) {
            if ($j.$k) { return $true }
        }
        return $false
    } catch { return $false }
}

function Find-MajesticJson {
    $std = Join-Path $env:APPDATA 'majestic-launcher\Multiplayer\majestic.json'
    if (Test-ValidMajesticJson $std) { return $std }
    $cands = Get-ChildItem "$env:APPDATA" -Recurse -Depth 4 -Filter 'majestic.json' -ErrorAction SilentlyContinue
    foreach ($c in $cands) { if (Test-ValidMajesticJson $c.FullName) { return $c.FullName } }
    $cands2 = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 4 -Filter 'majestic.json' -ErrorAction SilentlyContinue
    foreach ($c in $cands2) { if (Test-ValidMajesticJson $c.FullName) { return $c.FullName } }
    return $null
}

# ------------------------------------------------------------
# Majestic paths from its json (any schema variant)
# ------------------------------------------------------------
function Get-MajesticValue {
    param($MajesticJson, [string[]]$Keys)
    if (-not $MajesticJson -or -not (Test-Path -LiteralPath $MajesticJson)) { return $null }
    try {
        $j = Get-Content -LiteralPath $MajesticJson -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($k in $Keys) {
            if ($j.$k -and (Test-Path -LiteralPath ($j.$k -replace '"', ''))) { return ($j.$k -replace '"', '') }
        }
        return $null
    } catch { return $null }
}

function Get-MajesticCachePath {
    param($MajesticJson)
    Get-MajesticValue -MajesticJson $MajesticJson -Keys @('cachePath', 'cache', 'CachePath', 'cache_path')
}

function Get-MajesticGamePath {
    param($MajesticJson)
    Get-MajesticValue -MajesticJson $MajesticJson -Keys @('gamePath', 'installPath', 'gtaPath', 'gtapath')
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

# ------------------------------------------------------------
# Process detection: name-based (fast) first, then command-line
# fallback via CIM - THROTTLED to once per 20 s per pattern set (REVIEW-#13: comment kept in sync with the code).
# powershell/pwsh hosts are EXCLUDED from the command-line fallback
# (otherwise the watcher mistakes its own tools for Majestic).
# ------------------------------------------------------------
function Get-ExeNamesFromCommandLine {
    # pure: executable base names from a command line. ONLY tokens ending in
    # .exe count - "notepad C:\...\GTA5\settings.xml" must NOT look like the game.
    # Renamed binaries still work: launchers pass the real exe as an argument.
    # Accepted residual: 'explorer /select,"...\GTA5.exe"' still matches (rare).
    param([string]$CommandLine)
    if (-not $CommandLine) { return @() }
    $names = @()
    foreach ($m in [regex]::Matches($CommandLine, '"([^"]+\.exe)"|(\S+\.exe)(?=\s|"|$)')) {
        $tok = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        try { $names += [IO.Path]::GetFileNameWithoutExtension($tok) } catch {}
    }
    return @($names | Select-Object -Unique)
}

function Find-MatchingProcess {
    param([string[]]$Patterns)
    if (-not $Patterns) { return @() }
    $hits = @()
    try {
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            # explorer too: 'explorer /select,"...\GTA5.exe"' must not look like the game
            if ($p.Name -match '^(powershell|pwsh|explorer)(\.exe)?$') { continue }
            if ($Patterns | Where-Object { $p.Name -like "*$_*" }) { $hits += $p }
        }
    } catch {}
    if (-not $hits) {
        # cache is PER PATTERN SET: one shared cache made the launcher query return
        # the game query's result (and vice versa) for up to 20 s
        $key = ($Patterns -join '|').ToLower()
        $entry = $script:cimCache[$key]
        if ($entry -and (((Get-Date) - $entry.at).TotalSeconds -lt 20)) { return @($entry.hits) }
        $cimOk = $false
        try {
            foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
                # explorer too: 'explorer /select,"...\GTA5.exe"' must not look like the game
                if ($p.Name -match '^(powershell|pwsh|explorer)(\.exe)?$') { continue }
                $exeNames = @(Get-ExeNamesFromCommandLine $p.CommandLine)
                if ($p.ExecutablePath) {
                    try { $exeNames += [IO.Path]::GetFileNameWithoutExtension($p.ExecutablePath) } catch {}
                }
                if (-not $exeNames) { continue }
                if ($exeNames | Where-Object { $n = $_; $Patterns | Where-Object { $n -like "*$_*" } }) {
                    # Win32_Process has ProcessId, NOT Id - map it, or state.gamePid is $null
                    $hits += [pscustomobject]@{ Name = $p.Name; Id = [int]$p.ProcessId; CommandLine = $p.CommandLine }
                }
            }
            $cimOk = $true
        } catch {}
        # cache only on a clean scan - a failed query must not poison the cache
        if ($cimOk) { $script:cimCache[$key] = @{ at = (Get-Date); hits = $hits } }
    }
    return @($hits | Select-Object -Unique Name, Id, CommandLine)
}
$script:cimCache = @{}

# TTL cache for expensive profile walks, INCLUDING negative results:
# without it every menu redraw re-walks the whole profile when MG/Majestic
# is not installed. -Force bypasses (installer / repair / watcher start).
$script:walkCache = @{}
function Get-CachedWalk {
    param([string]$Key, [scriptblock]$Finder, [int]$TtlSec = 600, [switch]$Force)
    $e = $script:walkCache[$Key]
    if (-not $Force -and $e -and (((Get-Date) - $e.at).TotalSeconds -lt $TtlSec)) {
        if (($null -eq $e.value) -or (Test-Path -LiteralPath $e.value)) { return $e.value }
    }
    $v = & $Finder
    $script:walkCache[$Key] = @{ at = (Get-Date); value = $v }
    return $v
}

# ------------------------------------------------------------
# one-shot: resolve everything, persist to config, return config.
# -NoSave skips writing. Cached settingsXml is validated by
# EXISTENCE only (the running game holds settings.xml exclusively,
# so content reads can fail during a session).
# ------------------------------------------------------------
function Resolve-MgPaths {
    param([switch]$NoSave, [switch]$ForceFull)
    $cfg = Get-MgConfig
    # MG3-021: в тестовом режиме (MG_HELPER_DIR) config.json - единственный источник
    # правды. Полная переразведка иначе уводит watcher на ЖИВЫЕ пути пользователя:
    # интеграционный тест однажды так перезаписал настоящий settings.xml (поймано
    # сразу, но такой тест не должен иметь возможности это сделать в принципе).
    if ($env:MG_HELPER_DIR) { return $cfg }
    $changed = $false

    # cached path must EXIST (existence-only: game may hold the file open);
    # re-discover if missing, if the cached value is in Temp/backups, or
    # if the last full discovery is older than 24 h
    $cachedOk = $false
    if ($cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml) -and ($cfg.settingsXml -notmatch '\\Temp\\')) {
        $cachedOk = $true
    }
    $stale = $true
    try {
        $last = [datetime]$cfg.lastFullDiscovery
        $stale = ((Get-Date) - $last).TotalHours -ge 24
    } catch {}
    if (-not $cachedOk -or $ForceFull -or ($stale -and -not $NoSave)) {
        $found = Get-CachedWalk -Key 'settingsXml' -Finder { Find-SettingsXml } -Force:$ForceFull
        if ($found) {
            if ($found -ne $cfg.settingsXml) { $changed = $true }
            $cfg.settingsXml = $found
        }
        $cfg.lastFullDiscovery = (Get-Date).ToString('o')
        $changed = $true
    }

    # cached MG dir must be content-validated (empty leftovers poison the cache)
    if (-not $cfg.miamiGraphicsDir -or -not (Test-ValidMgDir $cfg.miamiGraphicsDir)) {
        $found = Get-CachedWalk -Key 'miamiGraphicsDir' -Finder { Find-MiamiGraphicsDir } -Force:$ForceFull
        if ($found) {
            if ($found -ne $cfg.miamiGraphicsDir) { $changed = $true }
            $cfg.miamiGraphicsDir = $found
        }
        elseif (-not $found -and $cfg.miamiGraphicsDir) { $cfg.miamiGraphicsDir = ''; $changed = $true }
    }
    # cached majestic.json must parse and look real
    if (-not $cfg.majesticJson -or -not (Test-ValidMajesticJson $cfg.majesticJson)) {
        $found = Get-CachedWalk -Key 'majesticJson' -Finder { Find-MajesticJson } -Force:$ForceFull
        if ($found) {
            if ($found -ne $cfg.majesticJson) { $changed = $true }
            $cfg.majesticJson = $found
        }
        elseif (-not $found -and $cfg.majesticJson) { $cfg.majesticJson = ''; $changed = $true }
    }

    # Documents location pin: if it CHANGED after install, the Rockstar SDK
    # breaks (error 1002) - diagnose warns via the docsPin comparison
    $docsPin = Get-DocsPin
    if ($docsPin -and ($cfg.docsRoot -ne $docsPin)) {   # don't rewrite config on every call
        $cfg.docsRoot = $docsPin
        $changed = $true
    }
    # 2.6.1: одноразовая миграция политики (см. Update-MgConfigPolicy):
    # установки 2.5/2.6 несут installer-default'ы onExit=adopt и guardWindowSec=120,
    # из-за которых защита вела себя не как в 1.x
    if (Update-MgConfigPolicy $cfg) { $changed = $true }
    if (-not $NoSave -and $changed) {
        if (-not (Save-MgConfig $cfg)) { Write-Warning 'MG Helper: paths discovered but config.json could NOT be saved - discovery will repeat next start' }
    }
    return $cfg
}

# ------------------------------------------------------------
# atomic write (temp + Replace, retry 3x, read-only cleared)
# ------------------------------------------------------------
function Write-Atomic {
    param([string]$Path, [byte[]]$Bytes)
    $tmp = "$Path.$PID.mgtmp"   # per-PID suffix: two concurrent writers must not share one tmp
    for ($try = 1; $try -le 3; $try++) {
        try {
            [IO.File]::WriteAllBytes($tmp, $Bytes)          # ВСЕГДА пишем tmp первым
            if (Test-Path -LiteralPath $Path) {
                $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
                if ($item -and $item.IsReadOnly) {
                    Set-ItemProperty -LiteralPath $Path -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                }
                [IO.File]::Replace($tmp, $Path, [NullString]::Value)
            } else {
                Move-Item -LiteralPath $tmp $Path -Force
            }
            return $true
        } catch {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }
    return $false
}

# ------------------------------------------------------------
# golden validation + self-heal chain
# ------------------------------------------------------------
function Test-GoldenValid {
    # MG-CR-003: full XML validation + minimum size (MG-CR-003's grep was not enough)
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        if ((Get-Item -LiteralPath $Path).Length -le 100) { return $false }
        return (Test-ValidSettingsXml -Path $Path)
    } catch { return $false }
}

function Get-ValidGolden {
    # 2.6.1: по умолчанию источником "лечения" может быть только НАШ эталон
    # (settings.golden.xml или его .bak, который создаётся при adopt). Раньше в
    # цепочку входили settings.before_apply.bak и ЖИВОЙ settings.xml, то есть при
    # повреждённом эталоне защита молча начинала защищать чужие настройки
    # (перезапись лаунчера). Живой fallback доступен только по явному запросу
    # (-AllowLiveFallback): так эталон восстанавливают осознанно - установщик
    # при невалидном эталоне копирует живые настройки сам, а этот ключ
    # оставлен для скриптов/проверок, которым нужен именно живой бэкап.
    param([string]$CfgSettingsXml, [switch]$AllowLiveFallback)
    $chain = @(
        (Join-Path $script:HelperDir 'settings.golden.xml'),
        (Join-Path $script:HelperDir 'settings.golden.xml.bak')
    )
    if ($AllowLiveFallback) {
        $chain += @(
            (Join-Path $script:HelperDir 'settings.before_apply.bak'),
            $CfgSettingsXml
        )
    }
    $first = $chain[0]
    foreach ($c in ($chain | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-GoldenValid $c) { return @{ path = $c; healed = ($c -ne $first) } }
    }
    return $null
}

function Apply-Golden {
    # MG-CR-002: read the VALIDATED source directly - never re-read from the
    # possibly-broken golden after a failed heal. The golden file is repaired
    # first, verified, and only then are the game settings written.
    param($Cfg)
    $src = Get-ValidGolden -CfgSettingsXml $Cfg.settingsXml
    if (-not $src) { return $false }
    $goldenPath = Join-Path $script:HelperDir 'settings.golden.xml'
    try {
        $goldenBytes = [IO.File]::ReadAllBytes($src.path)
        if ($src.healed) {
            if (-not (Write-Atomic -Path $goldenPath -Bytes $goldenBytes)) { return $false }
            if (-not (Test-GoldenValid $goldenPath)) { return $false }
        }
        return (Write-Atomic -Path $Cfg.settingsXml -Bytes $goldenBytes)
    }
    catch { return $false }
}

# ------------------------------------------------------------
# session helpers (used by the watcher, unit-tested by tools\check.ps1)
# ------------------------------------------------------------
function Get-FileMtimeUtc {
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc } catch { return [datetime]::MinValue }
}


# ------------------------------------------------------------
# 2.6.1 (MG3-002): watcher.health.json - доказательство живости watcher'а.
# watcher.ready говорит только "когда-то запускался" и после аварии остаётся,
# поэтому трей и диагностика обязаны смотреть на свежий heartbeat, а не на файл.
# ------------------------------------------------------------
function Get-WatcherHealthPath { Join-Path $script:HelperDir 'watcher.health.json' }

function Write-WatcherHealth {
    # атомарно (tmp -> Replace): читатель никогда не видит половину JSON
    param([string]$Status = 'running', [string]$Phase = 'Idle', $GamePid = $null,
          [string]$Version = '', [int]$Sequence = 0, [string]$LastErrorCode = $null)
    try {
        $startUtc = (Get-Date).ToUniversalTime()
        $p = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if ($p) { try { $startUtc = $p.StartTime.ToUniversalTime() } catch {} }
        $j = [ordered]@{
            schemaVersion    = 1
            pid              = $PID
            processStartUtc  = $startUtc.ToString('o')
            version          = $Version
            status           = $Status
            phase            = $Phase
            gamePid          = $GamePid
            lastHeartbeatUtc = (Get-Date).ToUniversalTime().ToString('o')
            sequence         = $Sequence
            lastErrorCode    = $LastErrorCode
        }
        New-Item -ItemType Directory -Force -Path $script:HelperDir | Out-Null
        $path = Get-WatcherHealthPath
        $tmp = "$path.$PID.tmp"
        [IO.File]::WriteAllText($tmp, ($j | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) }
        else { Move-Item -LiteralPath $tmp $path -Force }
        return $true
    } catch { return $false }
}

function Get-WatcherHealth {
    # tri-state для потребителей (трей, diagnose):
    #   Healthy  - status=running, heartbeat <= 15 c
    #   Degraded - 15..30 c или status=starting
    #   Stopped  - status=stopping, просрочка > 30 c
    #   Unknown  - файла нет / JSON битый / нет метки времени
    $path = Get-WatcherHealthPath
    if (-not (Test-Path -LiteralPath $path)) { return @{ status = 'Unknown'; data = $null; ageSec = $null } }
    try { $d = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json } catch {
        return @{ status = 'Unknown'; data = $null; ageSec = $null }
    }
    $hb = ConvertTo-UtcTime $d.lastHeartbeatUtc
    if (-not $hb) { return @{ status = 'Unknown'; data = $d; ageSec = $null } }
    $age = ((Get-Date).ToUniversalTime() - $hb).TotalSeconds
    if ($d.status -eq 'stopping') { return @{ status = 'Stopped'; data = $d; ageSec = $age } }
    # 2.6.1: status=starting - это ещё не рабочий watcher (он поднимает FSW,
    # сверяет ключ эталона и состояние). Свежий heartbeat тут не доказательство
    # защиты, поэтому Degraded, как и в трее.
    if ($d.status -eq 'starting') { return @{ status = 'Degraded'; data = $d; ageSec = $age } }
    if ($age -le 15) { return @{ status = 'Healthy'; data = $d; ageSec = $age } }
    if ($age -le 30) { return @{ status = 'Degraded'; data = $d; ageSec = $age } }
    return @{ status = 'Stopped'; data = $d; ageSec = $age }
}

# ------------------------------------------------------------
# 3.0 (этап 5a): клиент Named Pipe (docs/adr/ADR-003). Команды идут в watcher,
# ответ - JSON. Если канал недоступен (старая установка, другой пользователь),
# возвращается $null, и вызывающий использует файловый путь.
# ------------------------------------------------------------
function Get-MgPipeName {
    if ($env:MG_HELPER_DIR) { return 'MG_Helper_test' }
    return 'MG_Helper'
}

function Invoke-MgPipeCommand {
    param([string]$Command = 'status', [int]$TimeoutMs = 1500, [string]$PipeName)
    if (-not $PipeName) { $PipeName = Get-MgPipeName }
    $client = $null
    try {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $client.Connect($TimeoutMs)
        $writer = New-Object System.IO.StreamWriter($client)
        $writer.AutoFlush = $true
        $writer.WriteLine((@{ cmd = $Command } | ConvertTo-Json -Compress))
        $reader = New-Object System.IO.StreamReader($client)
        $line = $reader.ReadLine()
        if (-not $line) { return $null }
        return ($line | ConvertFrom-Json)
    } catch { return $null }
    finally { if ($client) { try { $client.Dispose() } catch {} } }
}

function Get-MgLiveStatus {
    # статус по каналу; при отказе - по health-файлу. source показывает, чем ответили.
    $piped = Invoke-MgPipeCommand -Command 'status'
    if ($piped -and $piped.ok -and $piped.status) { return @{ source = 'pipe'; data = $piped.status; health = [string]$piped.status.status; ageSec = $null } }
    $health = Get-WatcherHealth
    return @{ source = 'health'; data = $health.data; health = $health.status; ageSec = $health.ageSec }
}
function Get-XmlSignature {
    # structural signature of an XML document: every element becomes
    # "path [attr1=v1;attr2=v2]" with attributes SORTED - whitespace and
    # attribute order are insignificant (CI round 1, Pester finding).
    # NOTE: $lines is a List (reference type) because a scriptblock closure
    # invoking `& $walk` creates a child scope where `$lines += ...` would
    # silently create a local copy and lose all entries.
    param([string]$XmlText)
    try {
        $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null; $doc.LoadXml($XmlText)
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $walk = {
            param($node, $path)
            foreach ($child in @($node.ChildNodes)) {
                if ($child.NodeType -ne 'Element') { continue }
                $attrs = @($child.Attributes | ForEach-Object { "$($_.Name)=$($_.Value)" } | Sort-Object)
                $lines.Add(("{0} [{1}]" -f "$path/$($child.Name)", ($attrs -join ';')))
                & $walk $child "$path/$($child.Name)"
            }
        }
        & $walk ($doc.DocumentElement) ''
        return (($lines.ToArray() | Sort-Object) -join "`n")
    } catch { return $null }
}

function Test-SameSettings {
    # TRI-STATE: $true/$false - compared; $null - could not read (the game holds
    # the file exclusively). Callers MUST NOT treat $null as drift, otherwise
    # they fight the running game with pointless rewrites every few seconds.
    param([string]$A, [string]$B)
    try {
        $ra = [IO.File]::ReadAllText($A)
        $rb = [IO.File]::ReadAllText($B)
    } catch { return $null }
    try {
        # MG-CR-015 + CI finding: structural compare via sorted-attribute
        # signatures - insignificant whitespace AND attribute order are ignored
        $sigA = Get-XmlSignature -XmlText $ra
        $sigB = Get-XmlSignature -XmlText $rb
        if ($null -ne $sigA -and $null -ne $sigB) { return ($sigA -eq $sigB) }
    } catch {}
    # not parseable XML - fall back to the whitespace-insensitive text compare
    return (($ra -replace '\s+', '') -eq ($rb -replace '\s+', ''))
}




function Get-GoldenKeyInfo {
    # current machine identity: game variant + video card from the live settings
    param($Cfg)
    $variant = $null
    $gpu = $null
    try { $g = Find-GtaGameRoot; if ($g) { $variant = $g.variant } } catch {}
    try {
        $raw = Get-Content -LiteralPath $Cfg.settingsXml -Raw -ErrorAction Stop
        $gpu = ([regex]::Match($raw, '<VideoCardDescription>([^<]+)</VideoCardDescription>')).Groups[1].Value
    } catch {}
    return @{ variant = $variant; gpu = $gpu }
}

function Save-GoldenKey {
    # record the CURRENT machine identity as the golden key (called by install/
    # reset-settings after a fresh golden is created)
    param($Cfg)
    try {
        $info = Get-GoldenKeyInfo -Cfg $Cfg
        if (-not $info.variant -or -not $info.gpu) { return $false }
        $j = @{ variant = $info.variant; gpu = $info.gpu; created = (Get-Date).ToString('o') }
        [IO.File]::WriteAllText((Join-Path $script:HelperDir 'golden_key.json'), ($j | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        return $true
    } catch { return $false }
}

function Get-SavedGoldenKey {
    try {
        $f = Join-Path $script:HelperDir 'golden_key.json'
        if (-not (Test-Path -LiteralPath $f)) { return $null }
        return (Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch { return $null }
}


function Show-SettingsDiff {
    # prints "key: old -> new" for changed values; returns the change count
    param([string]$OldText, [string]$NewText, [int]$MaxLines = 40)
    $old = Get-SettingsKeyValues -XmlText $OldText
    $new = Get-SettingsKeyValues -XmlText $NewText
    $changes = 0
    foreach ($k in $new.Keys) {
        if (-not $old.ContainsKey($k) -or ($old[$k] -ne $new[$k])) {
            $changes++
            if ($changes -le $MaxLines) {
                $o = if ($old.ContainsKey($k)) { $old[$k] } else { '(absent)' }
                Write-Host ("  {0}: {1} -> {2}" -f $k, $o, $new[$k])
            }
        }
    }
    foreach ($k in $old.Keys) { if (-not $new.ContainsKey($k)) { $changes++ } }
    if ($changes -gt $MaxLines) { Write-Host ("  ... ещё {0} изменений" -f ($changes - $MaxLines)) }
    return $changes
}

function Get-WatcherProcess {
    # REVIEW-#9: ONE source of truth for "which processes run the watcher".
    # Excludes this process and -Diagnose runs (diagnose must not be killed by
    # install/repair, nor counted as a live watcher by the menu).
    param([int]$ExcludePid = $PID)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -OperationTimeoutSec 15 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $ExcludePid -and
            $_.CommandLine -match 'gta-settings-watcher\.ps1' -and
            $_.CommandLine -notmatch '-Diagnose'
        }
}

function Get-LatestBinArchive {
    # newest COMPLETE generation that actually contains .bin files.
    # REVIEW-#19: generations mid-copy (killed process, power loss) live in
    # "<stamp>.incomplete" folders and are ignored AND cleaned up here - only
    # the verified rename makes a generation trustworthy.
    $arcRoot = Join-Path $script:HelperDir 'vanilla_backup_archive'
    Get-ChildItem $arcRoot -Directory -Filter '*.incomplete' -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $gens = Get-ChildItem $arcRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.incomplete$' } |
        Sort-Object Name -Descending
    foreach ($g in $gens) {
        $files = @(Get-ChildItem $g.FullName -Filter '*.bin' -ErrorAction SilentlyContinue)
        if ($files.Count -gt 0) { return @{ dir = $g; files = $files } }
    }
    return $null
}

function Ensure-BinsRestored {
    # MG-CR-005 + REVIEW-#2: never reports success without verification, and a
    # 'partial' restore CONTINUES on the next tick (compare against the full
    # archive list, not "at least one bin exists" - that made partial restores
    # unfinished forever). Returns:
    #   'present'  - launcher already has ALL archived bins
    #   'restored' - all missing bins copied and size-verified
    #   'partial'  - some copied, some failed (retry next tick continues)
    #   'failed'   - nothing copied
    #   'none'     - no archive / no launcher backup dir
    param($Cfg)
    try {
        $bkDir = Get-MajesticBackupDir -Cfg $Cfg
        if (-not $bkDir -or -not (Test-Path -LiteralPath $bkDir)) { return 'none' }
        $arc = Get-LatestBinArchive
        if (-not $arc -or $arc.files.Count -eq 0) { return 'none' }
        $missing = @($arc.files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bkDir $_.Name)) })
        if ($missing.Count -eq 0) { return 'present' }
        $copied = 0
        $failed = 0
        foreach ($file in $missing) {
            $destination = Join-Path $bkDir $file.Name
            try {
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
                $actual = Get-Item -LiteralPath $destination -ErrorAction Stop
                if ($actual.Length -eq $file.Length) { $copied++ } else { $failed++ }
            } catch { $failed++ }
        }
        if ($failed -gt 0) { return 'partial' }
        if ($copied -eq $missing.Count) { return 'restored' }
        return 'failed'
    } catch { return 'failed' }
}

function Restore-VanillaBackup {
    # returns archived vanilla bins ONLY where they are missing in the launcher.
    # A stale archive must never downgrade bins the launcher created/updated
    # itself - that would re-introduce the Rockstar SDK error 1002.
    param($Cfg)
    try {
        $bkDir = Get-MajesticBackupDir -Cfg $Cfg
        if (-not $bkDir) { return $false }
        $arc = Get-LatestBinArchive
        if (-not $arc) { return $false }
        $copied = 0
        foreach ($f in $arc.files) {
            $dst = Join-Path $bkDir $f.Name
            if (-not (Test-Path -LiteralPath $dst)) {
                # REVIEW-#11: count VERIFIED copies, not attempts
                $okCopy = $false
                try {
                    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction Stop
                    $okCopy = ((Get-Item -LiteralPath $dst -ErrorAction Stop).Length -eq $f.Length)
                } catch { $okCopy = $false }
                if ($okCopy) { $copied++ }
            }
        }
        return ($copied -gt 0)
    } catch { return $false }
}

function Archive-VanillaBins {
    # builds the vanilla_backup_archive: copies (NEVER moves - no race with the
    # Majestic patcher, that race caused error 1002) the launcher's vanilla bins
    # right after the game closes. This is what makes Ensure-BinsRestored /
    # Restore-VanillaBackup actually work as 1002 insurance. Keeps $Keep newest
    # generations (each ~2 GB of local disk, zero network traffic).
    # $StopCheck: optional scriptblock; when it returns $true (e.g. the watcher's
    # stop-event fired), the copy aborts and the .incomplete folder is removed.
    param($Cfg, [int]$Keep = 2, [scriptblock]$StopCheck = $null)
    try {
        $bkDir = Get-MajesticBackupDir -Cfg $Cfg
        if (-not $bkDir -or -not (Test-Path -LiteralPath $bkDir)) { return $false }
        $bins = @(Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue)
        if ($bins.Count -eq 0) { return $false }
        # skip the multi-GB copy when the newest good generation is already identical:
        # launcher bins change only after ITS updates, not every game session.
        # Copy-Item preserves LastWriteTime, so archived mtime == source mtime.
        $prev = Get-LatestBinArchive
        if ($prev) {
            $unchanged = $true
            foreach ($b in $bins) {
                $p = Join-Path $prev.dir.FullName $b.Name
                if (-not (Test-Path -LiteralPath $p)) { $unchanged = $false; break }
                $li = Get-Item -LiteralPath $p
                if (($li.Length -ne $b.Length) -or ($li.LastWriteTimeUtc -ne $b.LastWriteTimeUtc)) { $unchanged = $false; break }
            }
            if ($unchanged) {
                # still run retention so old generations do not pile up
                $arcRoot = Join-Path $script:HelperDir 'vanilla_backup_archive'
                Get-ChildItem $arcRoot -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending |
                    Select-Object -Skip $Keep |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                return $false
            }
        }
        # free-space guard: never start a copy we cannot finish (torn generation)
        $need = ($bins | Measure-Object Length -Sum).Sum
        $free = (Get-Item -LiteralPath $script:HelperDir -ErrorAction SilentlyContinue).PSDrive.Free
        if (($null -ne $free) -and ($free -lt ($need + 500MB))) { return $false }
        $arcRoot = Join-Path $script:HelperDir 'vanilla_backup_archive'
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $finalDst = Join-Path $arcRoot $stamp
        # stamp collision: two calls within one second must not share a folder -
        # a failed copy into an EXISTING generation would delete its contents
        $uniq = 0
        while (Test-Path -LiteralPath $finalDst) { $uniq++; $finalDst = Join-Path $arcRoot ("$stamp-$uniq") }
        # REVIEW-#19: copy into "<name>.incomplete" and RENAME only after all
        # files are verified - a kill/power-loss mid-copy can no longer leave a
        # torn generation that Get-LatestBinArchive would trust
        $dst = "$finalDst.incomplete"
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        $ok = 0
        foreach ($b in $bins) {
            # cooperative stop check between multi-GB files (REVIEW-#19)
            if ($StopCheck -and (& $StopCheck)) {
                Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
                return $false
            }
            $d = Join-Path $dst $b.Name
            # try/catch is mandatory: with $ErrorActionPreference='Stop' in the
            # caller's scope a locked source THROWS past -ErrorAction, which would
            # skip the removal below and leave a torn "latest" generation
            try { Copy-Item -LiteralPath $b.FullName -Destination $d -Force -ErrorAction SilentlyContinue } catch {}
            # a locked source can leave a 0-byte/partial copy - verify length
            if ((Test-Path -LiteralPath $d) -and ((Get-Item -LiteralPath $d).Length -eq $b.Length)) { $ok++ }
        }
        if ($ok -ne $bins.Count) {
            # incomplete generation must never become "latest" nor eat retention slots
            Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
        # all verified -> the atomic rename makes this generation trustworthy
        Rename-Item -LiteralPath $dst -NewName (Split-Path $finalDst -Leaf) -Force
        # retention: keep only the newest generations
        Get-ChildItem $arcRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            Select-Object -Skip $Keep |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Prune-BackupFiles {
    # keeps only the newest $Keep timestamped backups matching a pattern
    # (settings.golden.xml.old_*, before_maxfps_*, before_shadows_* grow forever)
    param([string]$Pattern, [int]$Keep = 10)
    try {
        Get-ChildItem -LiteralPath $script:HelperDir -Filter $Pattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $Keep |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Get-OpJournalPath {
    param([string]$Name)
    Join-Path $script:HelperDir ("journal_{0}.json" -f $Name)
}

function Start-OpJournal {
    # ROADMAP 2.1: record a multi-file operation so a crash/kill mid-way can
    # be reconciled at watcher start (golden rolled back from the recorded backup)
    param([string]$Name)
    try {
        $j = @{ op = $Name; status = 'running'; started = (Get-Date).ToString('o'); steps = @() }
        [IO.File]::WriteAllText((Get-OpJournalPath $Name), ($j | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    } catch {}
}

function Set-OpJournalStep {
    param([string]$Name, [string]$Step, [string]$Status = 'done', [string]$Path = '')
    try {
        $f = Get-OpJournalPath $Name
        $j = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json
        $steps = @($j.steps)
        $found = $false
        foreach ($s in $steps) { if ($s.step -eq $Step) { $s.status = $Status; $s.path = $Path; $found = $true } }
        if (-not $found) { $steps += @{ step = $Step; status = $Status; path = $Path } }
        $j.steps = $steps
        [IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    } catch {}
}

function Complete-OpJournal {
    param([string]$Name, [string]$Status = 'done')
    try {
        $f = Get-OpJournalPath $Name
        $j = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json
        $j.status = $Status
        [IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    } catch {}
}

function Invoke-OpReconciliation {
    # called at watcher start: a journal left in 'running' means the process
    # died mid-operation -> restore the golden from the recorded backup, clean
    # torn artifacts (.incomplete generations, stale tmp files)
    param([scriptblock]$Logger = $null)
    function L($m) { if ($Logger) { & $Logger $m } }
    try {
        Get-ChildItem (Join-Path $script:HelperDir 'vanilla_backup_archive') -Directory -Filter '*.incomplete' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $script:HelperDir -Filter '*.mgtmp' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $goldenPath = Join-Path $script:HelperDir 'settings.golden.xml'
        Get-ChildItem -LiteralPath $script:HelperDir -Filter 'journal_*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $j = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($j.status -ne 'running') { return }
                $goldenDone = $false
                $bakPath = $null
                foreach ($st in @($j.steps)) {
                    if ($st.step -eq 'write-golden' -and $st.status -eq 'done') { $goldenDone = $true }
                    if ($st.step -eq 'backup' -and $st.status -eq 'done' -and $st.path) { $bakPath = $st.path }
                }
                if ($goldenDone -and $bakPath -and (Test-Path -LiteralPath $bakPath)) {
                    # the golden was written but the op never finished -> roll back
                    $rBytes = [IO.File]::ReadAllBytes($bakPath)
                    if (Write-Atomic -Path $goldenPath -Bytes $rBytes) {
                        L "[i] reconciliation: op '$($j.op)' rolled the golden back from $bakPath"
                    } else {
                        L "[!] reconciliation: could not roll the golden back from $bakPath - restore manually"
                    }
                } elseif ($goldenDone) {
                    L "[!] reconciliation: op '$($j.op)' died after writing the golden and no backup is recorded"
                } else {
                    L "[i] reconciliation: op '$($j.op)' died before any golden write - nothing to undo"
                }
                $j.status = 'recovered'
                [IO.File]::WriteAllText($_.FullName, ($j | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            } catch {
                L "[!] reconciliation: could not process $($_.Name): $_"
            }
        }
    } catch {
        L "[!] reconciliation error: $_"
    }
}

function Snapshot-MgFiles {
    # saves a full copy of MG json settings (nothing is ever deleted).
    # Extracted here so tools\check.ps1 can round-trip test it in isolation.
    # $Logger receives progress lines (the watcher passes its Log function);
    # -NoStandardScan skips the APPDATA/LOCALAPPDATA probe (tests use a fake dir).
    param($Cfg, [scriptblock]$Logger = $null, [switch]$NoStandardScan)
    function MLog($m) { if ($Logger) { & $Logger $m } }
    try {
        $dirs = @()
        if ($Cfg.miamiGraphicsDir -and (Test-Path -LiteralPath $Cfg.miamiGraphicsDir)) { $dirs += $Cfg.miamiGraphicsDir }
        if (-not $NoStandardScan) {
            foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
                $c = Join-Path $root 'MiamiGraphics'
                if ((Test-Path -LiteralPath $c) -and ($dirs -notcontains $c)) { $dirs += $c }
            }
        }
        if (@($dirs).Count -eq 0) { MLog "[i] MG dirs not found - snapshot skipped"; return }
        # ROADMAP 2.4: timestamped GENERATIONS (newest kept = 5). Each generation
        # is a folder with its own manifest.json - restore offers "MG settings as
        # of yesterday / the day before" instead of one overwrite-everything dir.
        $snapRoot = Join-Path $script:HelperDir 'mg_snapshot'
        $genDir = Join-Path $snapRoot (Get-Date -Format 'yyyy-MM-dd_HHmmss')
        # stamp collision safety (same-second calls)
        $uniq = 0
        while (Test-Path -LiteralPath $genDir) { $uniq++; $genDir = Join-Path $snapRoot ("{0}-{1}" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), $uniq) }
        New-Item -ItemType Directory -Force -Path $genDir | Out-Null
        # manifest maps snapshot file -> original relative path. The legacy '__'
        # flattening is ambiguous if a folder/file name itself contains '__';
        # restore prefers the manifest and falls back to the legacy decode.
        $manifest = [ordered]@{}
        # 2.6.1: roots.json - полный путь папки-источника для каждого файла.
        # Без него восстановление не знает, куда возвращать файл: 20 из 21 файла
        # на реальной машине лежат в %LOCALAPPDATA%\MiamiGraphics, а не в той
        # папке, которую config.json выбрал основной. Отдельный файл, а не ключ
        # внутри manifest.json: manifest читают старые установленные версии.
        $roots = [ordered]@{}
        $n = 0
        foreach ($dir in $dirs) {
            $rootFlat = ($dir -replace '[:\\/]', '_')
            foreach ($f in (Get-ChildItem $dir -Recurse -Depth 2 -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $name = "$rootFlat`__f$n.json"
                $manifest[$name] = $f.FullName.Substring($dir.Length).TrimStart('\')
                $roots[$name] = $dir
                Copy-Item -LiteralPath $f.FullName (Join-Path $genDir $name) -Force
                $n++
            }
        }
        if ($n -gt 0) {
            # atomic manifest write: a torn manifest.json must never exist
            $mf = Join-Path $genDir 'manifest.json'
            $tmp = "$mf.tmp"
            [IO.File]::WriteAllText($tmp, ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $mf) { [IO.File]::Replace($tmp, $mf, [NullString]::Value) }
            else { Move-Item -LiteralPath $tmp -Destination $mf -Force }
            $rf = Join-Path $genDir 'roots.json'
            $rtmp = "$rf.tmp"
            [IO.File]::WriteAllText($rtmp, ($roots | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $rf) { [IO.File]::Replace($rtmp, $rf, [NullString]::Value) }
            else { Move-Item -LiteralPath $rtmp -Destination $rf -Force }
            # retention: keep the newest 5 generations (legacy flat files are
            # untouched - restore still understands them as a fallback)
            Get-ChildItem $snapRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
                Sort-Object Name -Descending |
                Select-Object -Skip 5 |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            MLog "MG snapshot generation saved ($n files -> $genDir)"
        } else {
            Remove-Item -LiteralPath $genDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        MLog "[!] MG snapshot error: $_"
    }
}

# ------------------------------------------------------------
# Documents location pin: detect if the shell folder was MOVED
# (breaks the Rockstar Games SDK -> error 1002 "incomplete install")
# ------------------------------------------------------------
function Get-DocsPin {
    # Returns the CURRENT Documents location (User Shell Folders\Personal, expanded)
    try {
        $raw = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name Personal -ErrorAction Stop).Personal
        return [Environment]::ExpandEnvironmentVariables($raw)
    } catch { return $null }
}
