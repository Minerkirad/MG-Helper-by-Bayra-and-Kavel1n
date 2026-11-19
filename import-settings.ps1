# Imports a personal settings.xml into the golden backup and applies it now.
# The person's own settings become the permanent ones the watcher protects.
# Usage: put your settings.xml next to this script, run the bat.
# Universal v5: reads config.json first, falls back to discovery.
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'Import My Settings - by Bayra & Kavel1n'

$HelperDir  = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden     = Join-Path $HelperDir 'settings.golden.xml'
$ConfigFile = Join-Path $HelperDir 'config.json'
$Src        = Join-Path $PSScriptRoot 'settings.xml'

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

if (-not (Test-Path $Golden)) {
    Write-Host "[!] Golden not found. Run MG-Helper.bat -> [1] first." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $Src)) {
    Write-Host "[!] settings.xml not found next to this script." -ForegroundColor Red
    Write-Host "    Put your personal settings.xml into the same folder as the bat and run again."
    exit 1
}
if (-not $Settings) {
    Write-Host "[!] Current settings.xml not found on this PC." -ForegroundColor Red
    Write-Host "    Run GTA V once, or put the path into $ConfigFile (settingsXml)." -ForegroundColor DarkGray
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
    Write-Host "[!] GTA V is running - close the game first, then import again." -ForegroundColor Red
    exit 1
}

$srcText = Get-Content $Src -Raw   # NOT $src: PowerShell is case-insensitive, $Src is the PATH
if (-not ($srcText -match '<Settings>') -or ($srcText -match '\$\d')) {
    Write-Host "[!] The provided settings.xml is not valid - aborted, nothing changed." -ForegroundColor Red
    exit 1
}

# video block sanity: this PC's GPU must match the file's GPU (else GTA would re-detect)
$thisGpu = ([regex]::Match((Get-Content $Settings -Raw), '<VideoCardDescription>([^<]+)</VideoCardDescription>')).Groups[1].Value
$fileGpu = ([regex]::Match($srcText, '<VideoCardDescription>([^<]+)</VideoCardDescription>')).Groups[1].Value
if ($thisGpu -and $fileGpu -and ($thisGpu -ne $fileGpu)) {
    Write-Host "[!] GPU mismatch:" -ForegroundColor Red
    Write-Host "    file:    $fileGpu"
    Write-Host "    this PC: $thisGpu"
    Write-Host "    These settings are not from this PC - GTA would regenerate them."
    exit 1
}

Copy-Item $Golden (Join-Path $HelperDir 'settings.golden.xml.before_import.bak') -Force
$bytes = [Text.UTF8Encoding]::new($true).GetBytes($srcText)
$liveOk = $true
if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) {
    if (-not (Write-Atomic -Path $Golden -Bytes $bytes)) {
        Write-Host "[!] could not write golden (locked?) - aborted, nothing changed." -ForegroundColor Red
        exit 1
    }
    $liveOk = Write-Atomic -Path $Settings -Bytes $bytes   # Write-Atomic clears read-only itself
} else {
    if ((Get-Item $Settings).IsReadOnly) { Set-ItemProperty $Settings -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText($Golden, $srcText, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($Settings, $srcText, [Text.UTF8Encoding]::new($true))
}
if (-not $liveOk) {
    Write-Host "[!] golden updated, but live settings.xml is locked - the watcher applies it at next launch." -ForegroundColor Yellow
}

Write-Host "[+] Your personal settings are now the golden ones and applied." -ForegroundColor Green
Write-Host "[+] Previous golden saved as settings.golden.xml.before_import.bak" -ForegroundColor DarkGray
Write-Host "[+] The watcher will protect THESE settings at every launch." -ForegroundColor Green
