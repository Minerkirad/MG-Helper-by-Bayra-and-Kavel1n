# Applies friend's shadow-cut values to golden + settings.
# Universal v5: golden lives in %LOCALAPPDATA%\MG_Helper, paths from config.json.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Cut Shadows'

$HelperDir  = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden     = Join-Path $HelperDir 'settings.golden.xml'
$ConfigFile = Join-Path $HelperDir 'config.json'

# --- load universal discovery when available ---
$common = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'common.ps1'))) {
    $common = Join-Path $PSScriptRoot 'common.ps1'
} elseif (Test-Path -LiteralPath (Join-Path $HelperDir 'common.ps1')) {
    $common = Join-Path $HelperDir 'common.ps1'
}
if ($common) { . $common } else {
    function Find-SettingsXml {
        foreach ($d in @([Environment]::GetFolderPath('MyDocuments'), "$env:USERPROFILE\OneDrive\Documents", "$env:USERPROFILE\Documents")) {
            $c = Join-Path $d 'Rockstar Games\GTA V\settings.xml'
            if (Test-Path $c) { return $c }
        }
        return $null
    }
}

$Settings = $null
if (Test-Path $ConfigFile) {
    try { $cfg = Get-Content $ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $cfg = $null }
    if ($cfg -and $cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)) { $Settings = $cfg.settingsXml }
}
if (-not $Settings) { $Settings = Find-SettingsXml }

if (-not ((Test-Path $Golden) -and (Test-Path $Settings))) {
    Write-Host "[!] golden or settings.xml not found" -ForegroundColor Red
    Write-Host "    Run MG-Helper.bat -> [1] first, or check the paths in $ConfigFile" -ForegroundColor DarkGray
    exit 1
}

# refuse to fight a running game: it holds settings.xml and rewrites it on exit
$gameProcs = @('GTA5', 'GTA5_Enhanced')
if (Get-Command Find-MatchingProcess -ErrorAction SilentlyContinue) {
    $gameRunning = [bool](Find-MatchingProcess -Patterns $gameProcs)
} else {
    $gameRunning = [bool](Get-Process -Name $gameProcs -ErrorAction SilentlyContinue)
}
if ($gameRunning) {
    Write-Host "[!] GTA V is running - close the game first, then apply again." -ForegroundColor Red
    exit 1
}

$values = [ordered]@{
    'Shadow_SplitZStart'       = '-3.000000'
    'Shadow_SplitZEnd'         = '0.000000'
    'Shadow_aircraftExpWeight' = '-3.000000'
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Copy-Item $Golden (Join-Path $HelperDir "settings.golden.xml.before_shadows_$stamp") -Force
Copy-Item $Settings (Join-Path $HelperDir "settings.xml.before_shadows_$stamp") -Force
if (Get-Command Prune-BackupFiles -ErrorAction SilentlyContinue) {
    Prune-BackupFiles -Pattern 'settings.*before_shadows_*'   # keep the newest 10, prune the rest
}

# phase 1: merge + validate BOTH files before touching anything
$merged = @{}
foreach ($file in @($Golden, $Settings)) {
    $s = Get-Content $file -Raw
    $n = 0
    foreach ($k in $values.Keys) {
        $pattern = "(?<=<$k value=`")[^`"]*(?=`")"
        # case-insensitive replace; counter counts REAL changes ('-match' is ci, [regex]::Replace was cs)
        $new2 = [regex]::Replace($s, $pattern, $values[$k], [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($new2 -ne $s) { $s = $new2; $n++ }
    }
    if ($s -match '\$\d') { Write-Host "[!] corrupt merge - aborted, nothing changed" -ForegroundColor Red; exit 1 }
    $merged[$file] = @{ text = $s; count = $n }
}
# phase 2: atomic writes
foreach ($file in @($Golden, $Settings)) {
    $bytes = [Text.UTF8Encoding]::new($true).GetBytes($merged[$file].text)
    if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) {
        if (-not (Write-Atomic -Path $file -Bytes $bytes)) {
            Write-Host "[!] could not write $file (locked?) - profile NOT fully applied" -ForegroundColor Red
            exit 1
        }
    } else {
        [IO.File]::WriteAllBytes($file, $bytes)   # byte[] -> WriteAllBytes, NOT WriteAllText (byte[] -> decimal-garbage string)
    }
}
Write-Host "[+] Shadow-cut applied (golden: $($merged[$Golden].count), settings: $($merged[$Settings].count) values)" -ForegroundColor Green
Write-Host "[+] Backup: settings.golden.xml.before_shadows_$stamp / settings.xml.before_shadows_$stamp" -ForegroundColor DarkGray
