# Resets the golden backup to the CURRENT settings.xml on this PC.
# Use after setting up your own graphics in game. Old golden kept as timestamped backup.
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Reset Settings'

$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden    = Join-Path $HelperDir 'settings.golden.xml'

function Find-SettingsXml {
    $docsRoots = @(
        [Environment]::GetFolderPath('MyDocuments'),
        "$env:USERPROFILE\OneDrive\Documents",
        "$env:USERPROFILE\Documents"
    )
    foreach ($one in (Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
        $docsRoots += (Join-Path $one.FullName 'Documents')
    }
    foreach ($d in ($docsRoots | Select-Object -Unique)) {
        $c = Join-Path $d 'Rockstar Games\GTA V\settings.xml'
        if ($c -and (Test-Path $c)) { return $c }
    }
    $hits = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 5 -Filter 'settings.xml' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'Rockstar Games\\GTA V' } |
        Sort-Object LastWriteTime -Descending
    if ($hits) { return $hits[0].FullName }
    return $null
}

$Settings = Find-SettingsXml
if (-not (Test-Path $Golden)) {
    Write-Host "[!] Golden not found. Run 1-install.bat first." -ForegroundColor Red
    pause; exit 1
}
if (-not $Settings) {
    Write-Host "[!] settings.xml not found on this PC." -ForegroundColor Red
    pause; exit 1
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Copy-Item $Golden (Join-Path $HelperDir "settings.golden.xml.old_$stamp") -Force
if ((Get-Item $Settings).IsReadOnly) { Set-ItemProperty $Settings -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
Copy-Item $Settings $Golden -Force

$raw = Get-Content $Golden -Raw
$tq = [regex]::Match($raw, '<TextureQuality value="([^"]+)"').Groups[1].Value
$w  = [regex]::Match($raw, '<ScreenWidth value="([^"]+)"').Groups[1].Value
$h  = [regex]::Match($raw, '<ScreenHeight value="([^"]+)"').Groups[1].Value
Write-Host "[+] Golden reset to THIS PC's current settings." -ForegroundColor Green
Write-Host "    TextureQuality in golden: $tq"
Write-Host "    Resolution in golden:     $w x $h"
Write-Host "[+] The watcher will now always apply THESE settings." -ForegroundColor Green
pause
