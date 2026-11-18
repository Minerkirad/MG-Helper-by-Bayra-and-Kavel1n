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

# ------------------------------------------------------------
# config load/save (JSON, PS 5.1-safe)
# ------------------------------------------------------------
function Get-MgConfig {
    $cfg = [ordered]@{
        version          = 1
        settingsXml      = ''
        miamiGraphicsDir = ''
        majesticJson     = ''
        gameProcesses    = @('GTA5','GTA5_Enhanced')
        launcherProcesses= @('Majestic','MajesticLauncher','majestic-launcher')
        mgProcesses      = @('Miami','MiamiGraphics')
        useHotswapAgent  = $false
    }
    if (Test-Path $script:ConfigFile) {
        try {
            $loaded = Get-Content $script:ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in $cfg.Keys) {
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
        [IO.File]::WriteAllText($script:ConfigFile, $json, [Text.UTF8Encoding]::new($false))
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
# settings.xml discovery (multi-strategy, then bounded profile walk)
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
    foreach ($d in (Get-DocsRoots)) {
        foreach ($tail in @('Rockstar Games\GTA V\settings.xml', 'Rockstar Games\GTA V Enhanced\settings.xml')) {
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
# MiamiGraphics discovery (Roaming + Local + bounded profile walk)
# ------------------------------------------------------------
function Find-MiamiGraphicsDir {
    foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
        $c = Join-Path $root 'MiamiGraphics'
        if (Test-Path -LiteralPath $c -PathType Container) { return $c }
    }
    $cands = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 4 -Directory -Filter 'MiamiGraphics' -ErrorAction SilentlyContinue
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c.FullName -PathType Container) { return $c.FullName }
    }
    return $null
}

# ------------------------------------------------------------
# Majestic config discovery (APPDATA + bounded profile walk)
# ------------------------------------------------------------
function Find-MajesticJson {
    $std = Join-Path $env:APPDATA 'majestic-launcher\Multiplayer\majestic.json'
    if (Test-Path -LiteralPath $std) { return $std }
    $cands = Get-ChildItem "$env:APPDATA" -Recurse -Depth 4 -Filter 'majestic.json' -ErrorAction SilentlyContinue
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c.FullName) { return $c.FullName } }
    $cands2 = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 4 -Filter 'majestic.json' -ErrorAction SilentlyContinue
    foreach ($c in $cands2) { if (Test-Path -LiteralPath $c.FullName) { return $c.FullName } }
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
        # slow path: CIM command-line scan (only when name-based failed)
        try {
            foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
                if ($p.CommandLine) {
                    if ($Patterns | Where-Object { $p.CommandLine -match [regex]::Escape($_) }) { $hits += $p }
                }
            }
        } catch {}
    }
    return @($hits | Select-Object -Unique Name, Id, CommandLine)
}

# ------------------------------------------------------------
# one-shot: resolve everything, persist to config, return config.
# -NoSave skips writing (watcher loop calls this every 5 s)
# ------------------------------------------------------------
function Resolve-MgPaths {
    param([switch]$NoSave)
    $cfg = Get-MgConfig
    $changed = $false

    # cached path must exist AND be a valid settings.xml outside Temp/backups;
    # a poisoned cache (e.g. sandbox leftovers) is re-discovered automatically
    $cachedOk = $false
    if ($cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)) {
        $cachedOk = Test-ValidSettingsXml $cfg.settingsXml
    }
    if (-not $cachedOk) {
        $found = Find-SettingsXml
        if ($found -and ($found -ne $cfg.settingsXml)) {
            $cfg.settingsXml = $found; $changed = $true
        }
    }
    if (-not $cfg.miamiGraphicsDir -or -not (Test-Path -LiteralPath $cfg.miamiGraphicsDir)) {
        $found = Find-MiamiGraphicsDir
        if ($found) { $cfg.miamiGraphicsDir = $found; $changed = $true }
    }
    if (-not $cfg.majesticJson -or -not (Test-Path -LiteralPath $cfg.majesticJson)) {
        $found = Find-MajesticJson
        if ($found) { $cfg.majesticJson = $found; $changed = $true }
    }
    if (-not $NoSave -and $changed) { Save-MgConfig $cfg }
    return $cfg
}