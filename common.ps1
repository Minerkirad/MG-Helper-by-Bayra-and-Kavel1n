# ============================================================
#  MG Helper - common.ps1 (universal discovery + config + shared ops)
#  by Bayra & Kavel1n
#
#  Dot-sourced by the watcher, menu, repair and helper tools.
#  Everything here is PS 5.1-safe. The FILE must be UTF-8 with BOM.
# ============================================================

$script:Version = '1.6.5'   # держать в синке с version.json
$script:RepoSlug = 'Minerkirad/MG-Helper-by-Bayra-and-Kavel1n'
$script:HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$script:ConfigFile = Join-Path $script:HelperDir 'config.json'
$script:VersionFile = Join-Path $PSScriptRoot 'version.json'

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
        settingsXml       = ''
        miamiGraphicsDir  = ''
        majesticJson      = ''
        lastFullDiscovery = ''
        gameProcesses     = @('GTA5', 'GTA5_Enhanced')
        launcherProcesses = @('Majestic', 'MajesticLauncher', 'majestic-launcher')
        mgProcesses       = @('Miami', 'MiamiGraphics')
        useHotswapAgent   = $false
        autoArchiveBins   = $false
        autoCleanDlccache = $false
        onExit            = 'adopt'
        sessionGuard      = $true
        guardWindowSec    = 120
        notifications     = $true
        docsRoot          = (Get-DocsPin)
    }
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $loaded = Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in @($cfg.Keys)) {
                if ($null -ne $loaded.$p) { $cfg[$p] = $loaded.$p }
            }
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
    param($Config)
    try {
        New-Item -ItemType Directory -Force -Path $script:HelperDir -ErrorAction Stop | Out-Null
        $json = $Config | ConvertTo-Json -Depth 4
        $tmp = "$script:ConfigFile.tmp"
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $script:ConfigFile) { [IO.File]::Replace($tmp, $script:ConfigFile, [NullString]::Value) }
        else { Move-Item -LiteralPath $tmp $script:ConfigFile -Force }
    } catch {
        try {
            Remove-Item -LiteralPath $script:ConfigFile -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $tmp $script:ConfigFile -Force
        } catch {}
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
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ($Path -match '\\Temp\\|_settings_backup|MG_Helper') { return $false }
    try {
        $c = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return ($c -match '<Settings>' -and ($c -notmatch '\$\d'))
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
# fallback via CIM - THROTTLED to once per 60 s with cached result.
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
            if ($p.Name -match '^(powershell|pwsh)(\.exe)?$') { continue }
            if ($Patterns | Where-Object { $p.Name -like "*$_*" }) { $hits += $p }
        }
    } catch {}
    if (-not $hits) {
        # cache is PER PATTERN SET: one shared cache made the launcher query return
        # the game query's result (and vice versa) for up to 60 s
        $key = ($Patterns -join '|').ToLower()
        $entry = $script:cimCache[$key]
        if ($entry -and (((Get-Date) - $entry.at).TotalSeconds -lt 60)) { return @($entry.hits) }
        try {
            foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
                if ($p.Name -match '^(powershell|pwsh)(\.exe)?$') { continue }
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
        } catch {}
        $script:cimCache[$key] = @{ at = (Get-Date); hits = $hits }
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
    # breaks (error 1002) - warn the user via config.docsRootChanged
    $docsPin = Get-DocsPin
    if ($docsPin -and ($cfg.docsRoot -ne $docsPin)) {   # don't rewrite config on every call
        $cfg.docsRoot = $docsPin
        $changed = $true
    }
    if (-not $NoSave -and $changed) { Save-MgConfig $cfg }
    return $cfg
}

# ------------------------------------------------------------
# atomic write (temp + Replace, retry 3x, read-only cleared)
# ------------------------------------------------------------
function Write-Atomic {
    param([string]$Path, [byte[]]$Bytes)
    $tmp = "$Path.mgtmp"
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
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return ($raw.Length -gt 100 -and $raw -match '<Settings>' -and ($raw -notmatch '\$\d'))
    } catch { return $false }
}

function Get-ValidGolden {
    param([string]$CfgSettingsXml)
    $chain = @(
        (Join-Path $script:HelperDir 'settings.golden.xml'),
        (Join-Path $script:HelperDir 'settings.golden.xml.bak'),
        (Join-Path $script:HelperDir 'settings.before_apply.bak'),
        $CfgSettingsXml
    )
    foreach ($c in ($chain | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-GoldenValid $c) { return @{ path = $c; healed = ($c -ne $chain[0]) } }
    }
    return $null
}

function Apply-Golden {
    param($Cfg)
    $src = Get-ValidGolden -CfgSettingsXml $Cfg.settingsXml
    if (-not $src) { return $false }
    $goldenPath = Join-Path $script:HelperDir 'settings.golden.xml'
    if ($src.healed) {
        Copy-Item -LiteralPath $src.path $goldenPath -Force -ErrorAction SilentlyContinue
    }
    try { $goldenBytes = [IO.File]::ReadAllBytes($goldenPath) } catch { return $false }
    return (Write-Atomic -Path $Cfg.settingsXml -Bytes $goldenBytes)
}

# ------------------------------------------------------------
# session helpers (used by the watcher, unit-tested by tools\check.ps1)
# ------------------------------------------------------------
function Get-FileMtimeUtc {
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc } catch { return [datetime]::MinValue }
}

function Test-SameSettings {
    # whitespace-insensitive compare. TRI-STATE:
    #   $true/$false - compared;  $null - could not read (the game holds the file
    #   exclusively). Callers MUST NOT treat $null as drift, otherwise they fight
    #   the running game with pointless rewrites every few seconds.
    param([string]$A, [string]$B)
    try {
        $ra = [IO.File]::ReadAllText($A)
        $rb = [IO.File]::ReadAllText($B)
    } catch { return $null }
    return (($ra -replace '\s+', '') -eq ($rb -replace '\s+', ''))
}

function Test-GuardActive {
    # the drift-guard may run ONLY inside the launch window: that is when
    # Majestic/MG patch settings.xml. Later writes are the user's own changes.
    param($SessionStart, [int]$WindowSec, [bool]$GuardEnabled, [bool]$GameRunning)
    if (-not $GuardEnabled -or -not $GameRunning -or -not $SessionStart) { return $false }
    return (((Get-Date) - $SessionStart).TotalSeconds -lt $WindowSec)
}

function Test-AdoptCandidate {
    # pure decision: may the on-disk settings become the new golden?
    # $Same is the tri-state result of Test-SameSettings.
    # $AppliedThisSession: WE must have applied the golden at least once this
    # session. Otherwise $lastApplyUtc is MinValue, "changed after us" is always
    # true, and a Majestic overwrite could be adopted as the user's choice.
    param([bool]$ChangedAfterUs, [bool]$OnExitAdopt, $Same, [bool]$AppliedThisSession)
    return ($OnExitAdopt -and $AppliedThisSession -and $ChangedAfterUs -and ($Same -eq $false))
}

# ------------------------------------------------------------
# vanilla bins: ensure present in the launcher backup dir
# (safety net against the error-1002 stuck state)
# ------------------------------------------------------------
function Ensure-BinsRestored {
    param($Cfg)
    try {
        $bkDir = Get-MajesticBackupDir -Cfg $Cfg
        if (-not $bkDir -or -not (Test-Path -LiteralPath $bkDir)) { return 'none' }
        if (@(Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue).Count -gt 0) { return 'present' }
        $latest = Get-ChildItem (Join-Path $script:HelperDir 'vanilla_backup_archive') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { return 'none' }
        $files = Get-ChildItem $latest.FullName -Filter '*.bin' -ErrorAction SilentlyContinue
        if (-not $files) { return 'none' }
        $files | Copy-Item -Destination $bkDir -Force -ErrorAction SilentlyContinue
        return 'restored'
    } catch { return 'none' }
}

function Restore-VanillaBackup {
    # returns archived vanilla bins ONLY where they are missing in the launcher.
    # A stale archive must never downgrade bins the launcher created/updated
    # itself - that would re-introduce the Rockstar SDK error 1002.
    param($Cfg)
    try {
        $bkDir = Get-MajesticBackupDir -Cfg $Cfg
        if (-not $bkDir) { return $false }
        $arcRoot = Join-Path $script:HelperDir 'vanilla_backup_archive'
        $latest = Get-ChildItem $arcRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { return $false }
        $files = Get-ChildItem $latest.FullName -Filter '*.bin' -ErrorAction SilentlyContinue
        if (-not $files) { return $false }
        $copied = 0
        foreach ($f in $files) {
            $dst = Join-Path $bkDir $f.Name
            if (-not (Test-Path -LiteralPath $dst)) {
                Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction SilentlyContinue
                $copied++
            }
        }
        return ($copied -gt 0)
    } catch { return $false }
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

function Test-DocsRootChanged {
    # returns $true if the Documents location CHANGED from what config.json recorded
    param([string]$ConfiguredDocsRoot)
    $cur = Get-DocsPin
    if (-not $cur -or -not $ConfiguredDocsRoot) { return $false }
    return ($cur.TrimEnd('\') -ne $ConfiguredDocsRoot.TrimEnd('\'))
}
