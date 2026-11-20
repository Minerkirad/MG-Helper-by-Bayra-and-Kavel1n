# MG Helper - save current settings as a custom profile - by Bayra & Kavel1n
# ROADMAP 5.4: named profile = key/value overrides captured from the CURRENT
# golden; apply-custom-profile.ps1 re-applies them to golden + live settings.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Save Profile'
$ErrorActionPreference = 'Continue'

$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden = Join-Path $HelperDir 'settings.golden.xml'
$common = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'common.ps1'))) {
    $common = Join-Path $PSScriptRoot 'common.ps1'
} elseif (Test-Path -LiteralPath (Join-Path $HelperDir 'common.ps1')) {
    $common = Join-Path $HelperDir 'common.ps1'
}
if ($common) { . $common }

if (-not (Test-Path -LiteralPath $Golden)) {
    Write-Host "[!] Эталон не найден - сначала пункт меню [1]." -ForegroundColor Red
    exit 1
}

$name = Read-Host "Имя профиля (например: Мой тихий вечер)"
if (-not $name -or ($name -match '[\\/:*?"<>|]')) {
    Write-Host "[!] Некорректное имя." -ForegroundColor Red
    exit 1
}

$values = Get-SettingsKeyValues -XmlText (Get-Content $Golden -Raw)
$profilesFile = Join-Path $HelperDir 'profiles.json'
$profiles = @{}
if (Test-Path -LiteralPath $profilesFile) {
    try { $profiles = (Get-Content -LiteralPath $profilesFile -Raw -ErrorAction Stop | ConvertFrom-Json).profiles } catch { $profiles = @{} }
    if (-not $profiles) { $profiles = @{} }
}
# convert PSCustomObject to hashtable and set the entry
$ht = @{}
foreach ($p in $profiles.PSObject.Properties) { $ht[$p.Name] = $p.Value }
$ht[$name] = @{ values = $values; created = (Get-Date).ToString('o') }
$out = @{ profiles = $ht }
[IO.File]::WriteAllText($profilesFile, ($out | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

Write-Host "[+] Профиль '$name' сохранён ($($values.Count) параметров)." -ForegroundColor Green
Write-Host "[i] Применить: меню [14]." -ForegroundColor DarkGray
