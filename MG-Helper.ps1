# MG Helper menu - by Bayra & Kavel1n
$host.UI.RawUI.WindowTitle = 'MG Helper - by Bayra & Kavel1n'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = $PSScriptRoot

# remove Mark-of-the-Web from package files (downloaded archives get flagged)
Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# shared discovery module (status header uses it)
. (Join-Path $root 'common.ps1')

$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'

# --- update check: GitHub Releases latest vs this package version (once per 24h, silent on errors) ---
$PkgVersion = '1.4.1'
$RepoSlug   = 'Minerkirad/MG-Helper-by-Bayra-and-Kavel1n'
$global:UpdateMessage = $null
function Check-Updates {
    try {
        $chkFile = Join-Path $HelperDir 'update_check.txt'
        if ((Test-Path $chkFile) -and (((Get-Date) - (Get-Item $chkFile).LastWriteTime).TotalHours -lt 24)) { return }
        New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
        Set-Content -LiteralPath $chkFile -Value (Get-Date -Format 'o') -ErrorAction Stop
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -UseBasicParsing -TimeoutSec 10
        $tag = ($rel.tag_name -replace '^v','')
        if ($tag -and ($tag -ne $PkgVersion)) {
            $global:UpdateMessage = "Доступна новая версия: v$tag (у тебя $PkgVersion). Скачай ZIP на $RepoSlug/releases"
        }
    } catch { }   # offline / rate limit / GitHub недоступен - просто молчим
}
Check-Updates

function Confirm-It([string]$Text) {
    $r = Read-Host "$Text (да/нет)"
    return ($r -match '^(д|да|y|yes)$')
}

function Run-Step([string]$Label, [scriptblock]$Body) {
    Write-Host "`n--- $Label ---" -ForegroundColor Cyan
    & $Body
    Write-Host "[OK] Готово (если выше была ошибка - смотри текст или пункт [7])" -ForegroundColor DarkGray
    Read-Host "Нажми Enter, чтобы вернуться в меню" | Out-Null
}

function Show-Menu {
    Clear-Host
    Write-Host "=========================================================="
    Write-Host "           MG Helper - by Bayra & Kavel1n"
    Write-Host "=========================================================="

    # status header
    $cfg = Resolve-MgPaths -NoSave
    $installed = Test-Path (Join-Path $HelperDir 'gta-settings-watcher.ps1')
    $watchAlive = @(Find-MatchingProcess -Patterns @('gta-settings-watcher')).Count -gt 0
    $mgOk = $cfg.miamiGraphicsDir -and (Test-Path -LiteralPath $cfg.miamiGraphicsDir)
    $sxOk = $cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)

    Write-Host ""
    Write-Host "  Установка:    " -NoNewline
    if ($installed) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "не установлена - начни с пункта [1]" -ForegroundColor Red }
    Write-Host "  Ватчер:       " -NoNewline
    if ($watchAlive) { Write-Host "работает" -ForegroundColor Green } else { Write-Host "не запущен" -ForegroundColor $(if ($installed) { 'Yellow' } else { 'DarkGray' }) }
    Write-Host "  settings.xml: " -NoNewline
    if ($sxOk) { Write-Host "найден" -ForegroundColor Green } else { Write-Host "НЕ НАЙДЕН" -ForegroundColor Red }
    Write-Host "  Miami Graph.: " -NoNewline
    if ($mgOk) { Write-Host "найден" -ForegroundColor Green } else { Write-Host "не найден" -ForegroundColor $(if ($installed) { 'Yellow' } else { 'DarkGray' }) }
    if ($global:UpdateMessage) { Write-Host "  ОБНОВЛЕНИЕ:     $($global:UpdateMessage)" -ForegroundColor Yellow }
    Write-Host "=========================================================="
    Write-Host ""
    Write-Host "  [1] Установка          (запустить один раз)"
    Write-Host "  [2] Reset settings     (текущие настройки станут защищёнными)"
    Write-Host "  [3] Import settings    (импорт settings.xml из этой папки)"
    Write-Host "  [4] MAX FPS            (экстремальный профиль производительности)"
    Write-Host "  [5] Отключить тени     (максимальный FPS)"
    Write-Host "  [6] Очистка кэша       (ВНИМАНИЕ: перекачка десятков ГБ)"
    Write-Host ""
    Write-Host "  [7] Диагностика + отчёт (если что-то не работает)"
    Write-Host "  [8] Repair              (исправить типовые проблемы)"
    Write-Host "  [9] Удалить всё"
    Write-Host ""
    Write-Host "  [0] Выход"
    Write-Host ""
}

while ($true) {
    Show-Menu
    $choice = Read-Host "Выбери пункт"
    switch ($choice) {
        '1' { Run-Step "Установка" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install-gta-watcher.ps1') } }
        '2' { Run-Step "Reset settings" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'reset-settings.ps1') } }
        '3' { Run-Step "Import settings" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'import-settings.ps1') } }
        '4' {
            if (Confirm-It "MAX FPS - экстремальный профиль (пустые улицы, pop-in). Применить?") {
                Run-Step "MAX FPS" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'max-fps.ps1') }
            }
        }
        '5' {
            if (Confirm-It "Тени будут почти полностью отключены. Применить?") {
                Run-Step "Cut shadows" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'cut-shadows.ps1') }
            }
        }
        '6' { Run-Step "Clean cache" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'clean-majestic-cache.ps1') } }
        '7' { Run-Step "Diagnose" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'diagnose.ps1') } }
        '8' { Run-Step "Repair" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'repair.ps1') } }
        '9' {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'uninstall.ps1')
            Write-Host ""
            Write-Host "Удалено. Эту папку можно удалить."
            Read-Host "Нажми Enter для выхода"
            exit 0
        }
        '0' { exit 0 }
        default {
            Write-Host "Нет такого пункта. Введи цифру 0-9." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}
