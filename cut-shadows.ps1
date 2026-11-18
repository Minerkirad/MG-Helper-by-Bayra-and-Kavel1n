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
    Write-Host "    Run 1-install.bat first, or check the paths in $ConfigFile" -ForegroundColor DarkGray
    pause; exit 1
}

$values = [ordered]@{
    'Shadow_SplitZStart'       = '-3.000000'
    'Shadow_SplitZEnd'         = '0.000000'
    'Shadow_aircraftExpWeight' = '-3.000000'
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Copy-Item $Golden (Join-Path $HelperDir "settings.golden.xml.before_shadows_$stamp") -Force

$applied = 0
foreach ($file in @($Golden, $Settings)) {
    $s = Get-Content $file -Raw
    foreach ($k in $values.Keys) {
        $pattern = "(?<=<$k value=`")[^`"]*(?=`")"
        if ($s -match $pattern) { $s = [regex]::Replace($s, $pattern, $values[$k]); $applied++ }
    }
    if ($s -match '\$\d') { Write-Host "[!] corrupt merge - aborted" -ForegroundColor Red; pause; exit 1 }
    [IO.File]::WriteAllText($file, $s, [Text.UTF8Encoding]::new($true))
}
Write-Host "[+] Shadow-cut values applied ($applied per file)" -ForegroundColor Green
Write-Host "[+] Backup: settings.golden.xml.before_shadows_$stamp" -ForegroundColor DarkGray
pause