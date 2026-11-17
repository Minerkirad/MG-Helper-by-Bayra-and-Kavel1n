# Imports a personal settings.xml into the golden backup and applies it now.
# The person's own settings become the permanent ones the watcher protects.
# Usage: put your settings.xml next to this script, run the bat.
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'Import My Settings - by Bayra & Kavel1n'

$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden    = Join-Path $HelperDir 'settings.golden.xml'
$Src       = Join-Path $PSScriptRoot 'settings.xml'

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
if (-not (Test-Path $Src)) {
    Write-Host "[!] settings.xml not found next to this script." -ForegroundColor Red
    Write-Host "    Put your personal settings.xml into the same folder as the bat and run again."
    pause; exit 1
}

$src = Get-Content $Src -Raw
if (-not ($src -match '<Settings>') -or ($src -match '\$\d')) {
    Write-Host "[!] The provided settings.xml is not valid - aborted, nothing changed." -ForegroundColor Red
    pause; exit 1
}

# video block sanity: this PC's GPU must match the file's GPU (else GTA would re-detect)
$thisGpu = ([regex]::Match((Get-Content $Settings -Raw), '<VideoCardDescription>([^<]+)</VideoCardDescription>')).Groups[1].Value
$fileGpu = ([regex]::Match($src, '<VideoCardDescription>([^<]+)</VideoCardDescription>')).Groups[1].Value
if ($thisGpu -and $fileGpu -and ($thisGpu -ne $fileGpu)) {
    Write-Host "[!] GPU mismatch:" -ForegroundColor Red
    Write-Host "    file:    $fileGpu"
    Write-Host "    this PC: $thisGpu"
    Write-Host "    These settings are not from this PC - GTA would regenerate them."
    pause; exit 1
}

Copy-Item $Golden (Join-Path $HelperDir 'settings.golden.xml.before_import.bak') -Force
if ((Get-Item $Settings).IsReadOnly) { Set-ItemProperty $Settings -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
[IO.File]::WriteAllText($Golden, $src, [Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText($Settings, $src, [Text.UTF8Encoding]::new($true))

Write-Host "[+] Your personal settings are now the golden ones and applied." -ForegroundColor Green
Write-Host "[+] Previous golden saved as settings.golden.xml.before_import.bak" -ForegroundColor DarkGray
Write-Host "[+] The watcher will protect THESE settings at every launch." -ForegroundColor Green
pause
