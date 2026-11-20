# MG Helper - apply a custom profile - by Bayra & Kavel1n
# ROADMAP 5.4: applies a saved named profile to golden + live settings using
# the same transactional engine as the built-in profiles (two-phase merge,
# journal, rollback, diff-preview).
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Apply Profile'
$ErrorActionPreference = 'Continue'

$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden = Join-Path $HelperDir 'settings.golden.xml'
$ConfigFile = Join-Path $HelperDir 'config.json'
$common = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'common.ps1'))) {
    $common = Join-Path $PSScriptRoot 'common.ps1'
} elseif (Test-Path -LiteralPath (Join-Path $HelperDir 'common.ps1')) {
    $common = Join-Path $HelperDir 'common.ps1'
}
if ($common) { . $common }

$Settings = $null
if (Test-Path $ConfigFile) {
    try { $cfg = Get-Content $ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $cfg = $null }
    if ($cfg -and $cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)) { $Settings = $cfg.settingsXml }
}
if (-not $Settings) { $Settings = Find-SettingsXml }

if (-not ((Test-Path $Golden) -and (Test-Path $Settings))) {
    Write-Host "[!] Эталон или settings.xml не найдены - сначала пункт меню [1]." -ForegroundColor Red
    exit 1
}
# REVIEW: refuse to fight a running game
$gameProcs = @('GTA5', 'GTA5_Enhanced')
if (Get-Command Find-MatchingProcess -ErrorAction SilentlyContinue) {
    if ([bool](Find-MatchingProcess -Patterns $gameProcs)) {
        Write-Host "[!] GTA V запущена - закрой игру и повтори." -ForegroundColor Red
        exit 1
    }
}

$profilesFile = Join-Path $HelperDir 'profiles.json'
if (-not (Test-Path -LiteralPath $profilesFile)) {
    Write-Host "[!] Сохранённых профилей нет - сохрани через меню [15]." -ForegroundColor Yellow
    exit 1
}
$all = $null
try { $all = (Get-Content -LiteralPath $profilesFile -Raw -ErrorAction Stop | ConvertFrom-Json).profiles } catch { $all = $null }
if (-not $all -or -not $all.PSObject.Properties) {
    Write-Host "[!] Сохранённых профилей нет - сохрани через меню [15]." -ForegroundColor Yellow
    exit 1
}

Write-Host "Доступные профили:"
$names = @($all.PSObject.Properties.Name)
for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $names[$i]) }
$pick = Read-Host "Номер профиля (Enter = отмена)"
if ($pick -notmatch '^\d+$' -or ([int]$pick -lt 1) -or ([int]$pick -gt $names.Count)) { Write-Host "Отменено."; exit 0 }
$name = $names[[int]$pick - 1]
$values = $all.$name.values
if (-not $values) { Write-Host "[!] В профиле нет значений." -ForegroundColor Red; exit 1 }

# phase 1: merge + validate BOTH files before touching anything
$merged = @{}
foreach ($file in @($Golden, $Settings)) {
    $s = Get-Content $file -Raw
    $n = 0
    foreach ($k in $values.PSObject.Properties.Name) {
        $pattern = "(?<=<$k value=`")[^`"]*(?=`")"
        $new2 = [regex]::Replace($s, $pattern, [string]$values.$k, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($new2 -ne $s) { $s = $new2; $n++ }
    }
    if ($s -match '\$\d') { Write-Host "[!] corrupt merge - aborted, nothing changed" -ForegroundColor Red; exit 1 }
    $merged[$file] = @{ text = $s; count = $n }
}
# ROADMAP 5.3: diff-preview per file + confirm
Write-Host "[i] Изменения по файлам:"
$diffG = Show-SettingsDiff -OldText (Get-Content $Golden -Raw) -NewText $merged[$Golden].text -MaxLines 40
$diffS = Show-SettingsDiff -OldText (Get-Content $Settings -Raw) -NewText $merged[$Settings].text -MaxLines 40
if (($diffG -eq 0) -and ($diffS -eq 0)) { Write-Host "[i] Профиль не меняет ни одного параметра." -ForegroundColor Yellow; exit 0 }
$rc = Read-Host "Применить профиль '$name'? (да/нет)"
if ($rc -notmatch '^(д|да|y|yes)$') { Write-Host "Отменено."; exit 0 }

# backups + journal (same transactional model as built-in profiles)
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Copy-Item $Golden (Join-Path $HelperDir "settings.golden.xml.before_profile_$stamp") -Force
Copy-Item $Settings (Join-Path $HelperDir "settings.xml.before_profile_$stamp") -Force
if (Get-Command Prune-BackupFiles -ErrorAction SilentlyContinue) { Prune-BackupFiles -Pattern 'settings.*before_profile_*' }
Start-OpJournal 'profile-custom'
Set-OpJournalStep 'profile-custom' 'backup' 'done' (Join-Path $HelperDir "settings.golden.xml.before_profile_$stamp")

$goldenWritten = $false
foreach ($file in @($Golden, $Settings)) {
    $bytes = [Text.UTF8Encoding]::new($true).GetBytes($merged[$file].text)
    $wok = $false
    if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) { $wok = Write-Atomic -Path $file -Bytes $bytes }
    else { try { [IO.File]::WriteAllBytes($file, $bytes); $wok = $true } catch { $wok = $false } }
    if (-not $wok) {
        Write-Host "[!] could not write $file (locked?)" -ForegroundColor Red
        if ($goldenWritten) {
            $rBytes = [IO.File]::ReadAllBytes((Join-Path $HelperDir "settings.golden.xml.before_profile_$stamp"))
            $rOk = $false
            if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) { $rOk = Write-Atomic -Path $Golden -Bytes $rBytes }
            else { try { [IO.File]::WriteAllBytes($Golden, $rBytes); $rOk = $true } catch { $rOk = $false } }
            Complete-OpJournal 'profile-custom' $(if ($rOk) { 'rolled-back' } else { 'rollback-failed' })
            if ($rOk) { Write-Host "[!] golden ROLLED BACK - nothing changed." -ForegroundColor Yellow }
            else { Write-Host "[!] ОТКАТ НЕ ПОДТВЕРЖДЁН - восстанови вручную из $HelperDir\settings.golden.xml.before_profile_$stamp" -ForegroundColor Red }
        } else { Write-Host "[!] nothing was modified yet - aborting." -ForegroundColor Yellow }
        exit 1
    }
    if ($file -eq $Golden) { $goldenWritten = $true; Set-OpJournalStep 'profile-custom' 'write-golden' 'done' $Golden }
}
Complete-OpJournal 'profile-custom' 'done'
Write-Host "[+] Профиль '$name' применён (golden: $($merged[$Golden].count), settings: $($merged[$Settings].count) значений)." -ForegroundColor Green
