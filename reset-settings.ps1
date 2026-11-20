# Resets the golden backup to the CURRENT settings.xml on this PC.
# Use after setting up your own graphics in game. Old golden kept as timestamped backup.
# Universal v5: reads config.json first, falls back to discovery (common.ps1 when present).
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Reset Settings'

$HelperDir  = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden     = Join-Path $HelperDir 'settings.golden.xml'
$ConfigFile = Join-Path $HelperDir 'config.json'

# --- load universal discovery when available (encoded runs find it in MG_Helper) ---
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
    Write-Host "[!] Эталон не найден. Сначала выполни пункт меню [1] Установка." -ForegroundColor Red
    exit 1
}
if (-not $Settings) {
    Write-Host "[!] settings.xml не найден на этом ПК." -ForegroundColor Red
    Write-Host "    Запусти GTA V один раз, или впиши путь в $ConfigFile (settingsXml)." -ForegroundColor DarkGray
    exit 1
}
# source must be valid - otherwise we would "protect" a broken file
if ($common -and -not (Test-GoldenValid $Settings)) {
    Write-Host '[!] Текущий settings.xml пуст или повреждён - эталон НЕ обновлён.' -ForegroundColor Red
    Write-Host '    Запусти игру один раз, выстави графику, выйди и повтори.'
    exit 1
}
if (Get-Process -Name 'GTA5','GTA5_Enhanced' -ErrorAction SilentlyContinue) {
    Write-Host '[!] GTA5 запущена - настройки могут быть перезаписаны при выходе.' -ForegroundColor Yellow
    $r = Read-Host 'Всё равно продолжить? (да/нет)'
    if ($r -notmatch '^(д|да|y|yes)$') { Write-Host 'Отменено.'; exit 0 }
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Copy-Item $Golden (Join-Path $HelperDir "settings.golden.xml.old_$stamp") -Force
# ROADMAP 2.1: journal the operation for crash reconciliation
Start-OpJournal 'reset-golden'
Set-OpJournalStep 'reset-golden' 'backup' 'done' (Join-Path $HelperDir "settings.golden.xml.old_$stamp")
if ((Get-Item $Settings).IsReadOnly) { Set-ItemProperty $Settings -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }

# MG-CR-008: atomic write + verify the NEW golden before claiming success
$resetBytes = [IO.File]::ReadAllBytes($Settings)
# ROADMAP 5.3: diff-preview - show what exactly will change, confirm
$newText = [Text.UTF8Encoding]::new($true).GetString($resetBytes)
$oldText = Get-Content $Golden -Raw
$diffN = Show-SettingsDiff -OldText $oldText -NewText $newText -MaxLines 40
if ($diffN -eq 0) { Write-Host "[i] Различий с текущим эталоном нет - менять нечего." -ForegroundColor Yellow; Complete-OpJournal 'reset-golden' 'no-changes'; exit 0 }
Write-Host ("[i] Изменений: " + $diffN)
$rc = Read-Host "Применить и защитить эти настройки? (да/нет)"
if ($rc -notmatch '^(д|да|y|yes)$') { Write-Host "Отменено."; Complete-OpJournal 'reset-golden' 'cancelled'; exit 0 }
$resetOk = $false
if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) {
    $resetOk = Write-Atomic -Path $Golden -Bytes $resetBytes
} else {
    try { [IO.File]::WriteAllBytes($Golden, $resetBytes); $resetOk = $true } catch { $resetOk = $false }
}
if (-not $resetOk) {
    Complete-OpJournal 'reset-golden' 'failed'
    Write-Host "[!] Не удалось записать эталон (файл заблокирован?) - эталон НЕ изменён, старая копия: settings.golden.xml.old_$stamp" -ForegroundColor Red
    exit 1
}
Set-OpJournalStep 'reset-golden' 'write-golden' 'done' $Golden
if ($common -and -not (Test-GoldenValid $Golden)) {
    Complete-OpJournal 'reset-golden' 'failed'
    Write-Host "[!] Новый эталон не прошёл проверку после записи - восстановлена прежняя копия." -ForegroundColor Red
    Copy-Item (Join-Path $HelperDir "settings.golden.xml.old_$stamp") $Golden -Force
    exit 1
}
Complete-OpJournal 'reset-golden' 'done'
# ROADMAP 2.3: re-record the machine identity with the fresh golden
$null = Save-GoldenKey -Cfg @{ settingsXml = $Golden }

$raw = Get-Content $Golden -Raw
$tq = [regex]::Match($raw, '<TextureQuality value="([^"]+)"').Groups[1].Value
$w  = [regex]::Match($raw, '<ScreenWidth value="([^"]+)"').Groups[1].Value
$h  = [regex]::Match($raw, '<ScreenHeight value="([^"]+)"').Groups[1].Value
Write-Host "[+] Golden reset to THIS PC's current settings." -ForegroundColor Green
Write-Host "    TextureQuality in golden: $tq"
Write-Host "    Resolution in golden:     $w x $h"
Write-Host "[+] The watcher will now always apply THESE settings." -ForegroundColor Green
