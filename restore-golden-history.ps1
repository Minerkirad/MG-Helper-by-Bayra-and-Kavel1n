# MG Helper - golden history (undo) - by Bayra & Kavel1n
# ROADMAP 5.3: list the timestamped golden backups and restore the picked one.
# The current golden is rotated into old_<stamp> first (nothing is lost).
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Golden History'
$ErrorActionPreference = 'Continue'

$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$common = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'common.ps1'))) {
    $common = Join-Path $PSScriptRoot 'common.ps1'
} elseif (Test-Path -LiteralPath (Join-Path $HelperDir 'common.ps1')) {
    $common = Join-Path $HelperDir 'common.ps1'
}
if ($common) { . $common }

$Golden = Join-Path $HelperDir 'settings.golden.xml'
if (-not (Test-Path -LiteralPath $Golden)) {
    Write-Host "[!] Эталон не найден - сначала пункт меню [1]." -ForegroundColor Red
    exit 1
}

# candidates: all timestamped golden backups (history) - validated live below
$cands = @(Get-ChildItem -LiteralPath $HelperDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^settings\.golden\.xml\.(old_\d{4}-|before_)' -or $_.Name -eq 'settings.golden.xml.bak' } |
    Sort-Object LastWriteTime -Descending)
if ($cands.Count -eq 0) {
    Write-Host "[!] История эталона пуста - бэкапы появятся после adopt/профилей/reset." -ForegroundColor Yellow
    exit 0
}

Write-Host "============================================="
Write-Host " Golden history (undo) - by Bayra & Kavel1n"
Write-Host "============================================="
Write-Host ""
$valid = @()
for ($i = 0; $i -lt $cands.Count; $i++) {
    $c = $cands[$i]
    $ok = Test-ValidSettingsXml -Path $c.FullName
    $age = $c.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    if ($ok) {
        $valid += $c
        Write-Host ("  [{0}] {1}  {2}  [OK]" -f $valid.Count, $c.Name, $age)
    } else {
        Write-Host ("  [x] {0}  {1}  [БИТЫЙ]" -f $c.Name, $age) -ForegroundColor DarkGray
    }
}
Write-Host ""
Write-Host "[i] Восстановлены могут быть только файлы с [OK]. Текущий эталон будет сохранён в old_<время>." -ForegroundColor DarkGray
$pick = Read-Host "Номер файла для восстановления (Enter = отмена)"
if ($pick -notmatch '^\d+$') { Write-Host "Отменено."; exit 0 }
$pickIdx = [int]$pick
if ($pickIdx -lt 1 -or $pickIdx -gt $valid.Count) { Write-Host "[!] Нет такого номера." -ForegroundColor Red; exit 1 }
$src = $valid[$pickIdx - 1]

# rotate current golden first (undo of the undo is possible)
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Copy-Item -LiteralPath $Golden (Join-Path $HelperDir "settings.golden.xml.old_$stamp") -Force -ErrorAction SilentlyContinue

$bytes = [IO.File]::ReadAllBytes($src.FullName)
$okW = $false
if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) { $okW = Write-Atomic -Path $Golden -Bytes $bytes }
else { try { [IO.File]::WriteAllBytes($Golden, $bytes); $okW = $true } catch { $okW = $false } }
if (-not $okW -or -not (Test-GoldenValid $Golden)) {
    Write-Host "[!] Запись/проверка не удалась - эталон восстановлен из old_$stamp." -ForegroundColor Red
    Copy-Item (Join-Path $HelperDir "settings.golden.xml.old_$stamp") $Golden -Force
    exit 1
}
Write-Host "[+] Эталон восстановлен из $($src.Name)." -ForegroundColor Green
Write-Host "[+] Прежний эталон: settings.golden.xml.old_$stamp" -ForegroundColor DarkGray
Write-Host "[i] Применится при следующем запуске игры (или [12] не нужен - watcher подхватит)." -ForegroundColor DarkGray
