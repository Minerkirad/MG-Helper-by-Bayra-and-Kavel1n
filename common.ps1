# ============================================================
#  MG Helper - common.ps1 (universal discovery + config)
#  by Bayra & Kavel1n
#
#  Shared by the watcher and all helper tools (reset/import/
#  clean/maxfps/shadows). Everything here is PS 5.1-safe.
#
#  The ONE idea: never assume where things live. Discover
#  settings.xml / MiamiGraphics / Majestic on THIS PC, cache the
#  result in config.json next to the helper, and let a human
#  override any value by editing that file.
# ============================================================

$script:HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$script:ConfigFile = Join-Path $script:HelperDir 'config.json'
$script:Version = '1.5.0'
# CIM command-line scan is expensive - throttle it (min interval + cached result)
$script:lastCimScan = [datetime]::MinValue
$script:lastCimHits = @()

# ------------------------------------------------------------
# config load/save (JSON, PS 5.1-safe)
# ------------------------------------------------------------
function Get-MgConfig {
    $cfg = [ordered]@{
        version           = 1
        settingsXml       = ''
        miamiGraphicsDir  = ''
        majesticJson      = ''
        lastFullDiscovery = ''
        gameProcesses     = @('GTA5','GTA5_Enhanced')
        launcherProcesses = @('Majestic','MajesticLauncher','majestic-launcher')
        mgProcesses       = @('Miami','MiamiGraphics')
        useHotswapAgent   = $false
        autoArchiveBins   = $false
    }
    if (Test-Path $script:ConfigFile) {
        try {
            $loaded = Get-Content $script:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in @($cfg.Keys)) {
                if ($null -ne $loaded.$p) { $cfg[$p] = $loaded.$p }
            }
        } catch {
            # config exists but is broken - leave defaults, rewrite on Save
            Write-Host "[i] config.json unreadable ($($_.Exception.Message)); using defaults" -ForegroundColor DarkGray
        }
    }
    return $cfg
}

function Save-MgConfig {
    param($Config)
    try {
        New-Item -ItemType Directory -Force -Path $script:HelperDir -ErrorAction Stop | Out-Null
        $json = $Config | ConvertTo-Json -Depth 4
        # near-atomic replace: no torn reads while the watcher re-reads the config
        $tmp = "$script:ConfigFile.tmp"
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $script:ConfigFile -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $tmp $script:ConfigFile -Force
    } catch {
        Write-Host "[i] could not save config: $($_.Exception.Message)" -ForegroundColor DarkGray
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
    # registry KFM (finds any custom "Документы" location, incl. OneDriveДокументы)
    try {
        $personal = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name Personal -ErrorAction Stop).Personal
        if ($personal) {
            $expanded = [Environment]::ExpandEnvironmentVariables($personal)
            if ($expanded -match '^(?:[A-Za-z]:|\\\\)') { $roots += $expanded }
        }
    } catch {}
    # any OneDrive* folder at profile root (localized names: OneDrive, OneDriveДокументы, OneDrive - Org...)
    foreach ($one in (Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
        $roots += $one.FullName
        $roots += (Join-Path $one.FullName 'Documents')
        $roots += (Join-Path $one.FullName 'Документы')
    }
    return ($roots | Where-Object { $_ } | Select-Object -Unique)
}

# ------------------------------------------------------------
# GTA install discovery via registry (Steam / Epic / Rockstar)
# Returns @{ root = <game dir>; variant = 'GTA V' | 'GTA V Enhanced' } or $null
# Used to pick the right settings.xml tail (Enhanced uses its own Documents dir)
# ------------------------------------------------------------
function Find-GtaGameRoot {
    $roots = @()

    # Steam: SteamPath + all library folders from libraryfolders.vdf
    try {
        $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        $libs = @($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in ([regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"'))) {
                $libs += ($m.Groups[1].Value -replace '\\\\','\')
            }
        }
        foreach ($lib in ($libs | Select-Object -Unique)) {
            foreach ($tail in @('steamapps\common\Grand Theft Auto V', 'steamapps\common\Grand Theft Auto V Enhanced')) {
                $roots += (Join-Path $lib $tail)
            }
        }
    } catch {}

    # Epic: manifest items often under ProgramData; check common roots
    foreach ($r in @("$env:ProgramData\Epic\EpicGamesLauncher", "$env:ProgramFiles\Epic Games")) {
        if (Test-Path -LiteralPath $r) { $roots += $r }
    }

    # Rockstar / generic uninstall keys mentioning GTA
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
# settings.xml discovery (multi-strategy, then bounded profile walk)
# Tail ORDER depends on the discovered game variant (Enhanced vs Legacy)
# ------------------------------------------------------------
function Test-ValidSettingsXml {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    # never trust anything from Temp / sandbox / our own backups
    if ($Path -match '\\Temp\\|_settings_backup|MG_Helper') { return $false }
    try {
        $c = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return ($c -match '<Settings>' -and ($c -notmatch '\$\d'))
    } catch { return $false }
}

function Find-SettingsXml {
    # variant-aware tail order (registry finds the installed game version)
    $tails = @('Rockstar Games\GTA V\settings.xml', 'Rockstar Games\GTA V Enhanced\settings.xml')
    $game = Find-GtaGameRoot
    if ($game -and $game.variant -eq 'GTA V Enhanced') {
        $tails = @('Rockstar Games\GTA V Enhanced\settings.xml', 'Rockstar Games\GTA V\settings.xml')
    }

    foreach ($d in (Get-DocsRoots)) {
        foreach ($tail in $tails) {
            $c = Join-Path $d $tail
            if ((Test-Path -LiteralPath $c -PathType Leaf) -and (Test-ValidSettingsXml $c)) { return $c }
        }
    }
    # bounded recursive walk: only dirs matching *GTA V* or *Rockstar*,
    # never inside Temp / backup folders, content validated
    $cands = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 6 -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'GTA\s*V|Rockstar' -and $_.FullName -notmatch '\\Temp\\|_settings_backup|MG_Helper' }
    foreach ($c in $cands) {
        $f = Join-Path $c.FullName 'settings.xml'
        if ((Test-Path -LiteralPath $f -PathType Leaf) -and (Test-ValidSettingsXml $f)) {
            return $f
        }
    }
    return $null
}

# ------------------------------------------------------------
# MiamiGraphics discovery (Roaming + Local + bounded profile walk),
# content-validated: a real MG dir has config\ or a known json inside
# ------------------------------------------------------------
function Test-ValidMgDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($probe in @('config\installed_version.txt','config\gpu.json','install_state.json','optimization_baseline.json','gta_settings_preset.json','config\optimization_mods.json')) {
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
# Majestic config discovery (APPDATA + bounded profile walk),
# content-validated: must parse as JSON with a cachePath-like key
# ------------------------------------------------------------
function Test-ValidMajesticJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($k in @('cachePath','gamePath','installPath','gtaPath','name')) {
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
# Majestic cache path from its json (any schema: cachePath / cache / CachePath)
# ------------------------------------------------------------
function Get-MajesticCachePath {
    param($MajesticJson)
    if (-not $MajesticJson -or -not (Test-Path -LiteralPath $MajesticJson)) { return $null }
    try {
        $j = Get-Content $MajesticJson -Raw | ConvertFrom-Json
        foreach ($k in @('cachePath','cache','CachePath','cache_path')) {
            if ($j.$k -and (Test-Path -LiteralPath ($j.$k -replace '"',''))) { return ($j.$k -replace '"','') }
        }
        return $null
    } catch { return $null }
}

# ------------------------------------------------------------
# Process detection: by process NAME first, then any process whose
# COMMAND LINE contains one of the patterns (covers renamed binaries).
# The expensive CIM scan is THROTTLED: max once per 60 s, result cached.
# Returns matching process objects (Name, Id, CommandLine).
# ------------------------------------------------------------
function Find-MatchingProcess {
    param([string[]]$Patterns)
    if (-not $Patterns) { return @() }
    $hits = @()
    try {
        foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
            if ($Patterns | Where-Object { $p.Name -like "*$_*" }) { $hits += $p }
        }
    } catch {}
    if (-not $hits) {
        # slow path: CIM command-line scan - throttled to once per 60 s
        $since = ((Get-Date) - $script:lastCimScan).TotalSeconds
        if ($since -lt 60) { return @($script:lastCimHits) }
        $script:lastCimScan = Get-Date
        try {
            foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
                if ($p.CommandLine) {
                    if ($Patterns | Where-Object { $p.CommandLine -match [regex]::Escape($_) }) { $hits += $p }
                }
            }
        } catch {}
        $script:lastCimHits = $hits
    }
    return @($hits | Select-Object -Unique Name, Id, CommandLine)
}

# ------------------------------------------------------------
# one-shot: resolve everything, persist to config, return config.
# -NoSave skips writing (watcher loop calls this every 5 s)
# ------------------------------------------------------------
function Resolve-MgPaths {
    param([switch]$NoSave, [switch]$ForceFull)
    $cfg = Get-MgConfig
    $changed = $false

    # cached path must exist AND be a valid settings.xml outside Temp/backups;
    # a poisoned cache (e.g. sandbox leftovers) is re-discovered automatically
    $cachedOk = $false
    if ($cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)) {
        $cachedOk = Test-ValidSettingsXml $cfg.settingsXml
    }
    # full re-discovery at most once per 24 h (catches relocated installs)
    $stale = $true
    try {
        $last = [datetime]$cfg.lastFullDiscovery
        $stale = ((Get-Date) - $last).TotalHours -ge 24
    } catch {}
    if (-not $cachedOk -or $ForceFull -or ($stale -and -not $NoSave)) {
        $found = Find-SettingsXml
        if ($found -and ($found -ne $cfg.settingsXml)) {
            $cfg.settingsXml = $found; $changed = $true
        }
        $cfg.lastFullDiscovery = (Get-Date).ToString('o'); $changed = $true
    }

    # cached MG dir must be content-validated (empty leftovers poison the cache)
    if (-not $cfg.miamiGraphicsDir -or -not (Test-ValidMgDir $cfg.miamiGraphicsDir)) {
        $found = Find-MiamiGraphicsDir
        if ($found -and ($found -ne $cfg.miamiGraphicsDir)) {
            $cfg.miamiGraphicsDir = $found; $changed = $true
        }
        elseif (-not $found -and $cfg.miamiGraphicsDir) { $cfg.miamiGraphicsDir = ''; $changed = $true }
    }
    # cached majestic.json must parse and look real
    if (-not $cfg.majesticJson -or -not (Test-ValidMajesticJson $cfg.majesticJson)) {
        $found = Find-MajesticJson
        if ($found -and ($found -ne $cfg.majesticJson)) {
            $cfg.majesticJson = $found; $changed = $true
        }
        elseif (-not $found -and $cfg.majesticJson) { $cfg.majesticJson = ''; $changed = $true }
    }
    if (-not $NoSave -and $changed) { Save-MgConfig $cfg }
    return $cfg
}

# ------------------------------------------------------------
# Majestic game path from extra json keys (gamePath / installPath / gtaPath)
# Used by Diagnose to show the launcher's game folder + variant
# ------------------------------------------------------------
function Get-MajesticGamePath {
    param($MajesticJson)
    if (-not $MajesticJson -or -not (Test-Path -LiteralPath $MajesticJson)) { return $null }
    try {
        $j = Get-Content $MajesticJson -Raw | ConvertFrom-Json
        foreach ($k in @('gamePath','installPath','gtaPath')) {
            if ($j.$k -and (Test-Path -LiteralPath ($j.$k -replace '"',''))) { return ($j.$k -replace '"','') }
        }
        return $null
    } catch { return $null }
}