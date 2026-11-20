# MG Helper menu - by Bayra & Kavel1n
$host.UI.RawUI.WindowTitle = 'MG Helper - by Bayra & Kavel1n'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = $PSScriptRoot

# remove Mark-of-the-Web from package files (downloaded archives get flagged)
Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# shared discovery module (status header uses it)
. (Join-Path $root 'common.ps1')

$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'

# --- update check: GitHub Releases latest vs version.json (once per 24h, silent on errors) ---
$script:PkgVersion = Get-PkgVersion
$RepoSlug   = 'Minerkirad/MG-Helper-by-Bayra-and-Kavel1n'
$global:UpdateMessage = $null
function Check-Updates {
    try {
        $chkFile = Join-Path $HelperDir 'update_check.txt'
        if ((Test-Path $chkFile) -and (((Get-Date) - (Get-Item $chkFile).LastWriteTime).TotalHours -lt 24)) { return }
        New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -UseBasicParsing -TimeoutSec 10
        Set-Content -LiteralPath $chkFile -Value (Get-Date -Format 'o') -ErrorAction Stop   # only AFTER success - a network failure must not silence checks for 24h
        $tag = ($rel.tag_name -replace '^v','')
        try {
            if ($tag -and ([version]$tag -gt [version]$script:PkgVersion)) {
                $global:UpdateMessage = "Доступна новая версия: v$tag (у тебя $script:PkgVersion). Скачай ZIP: $RepoSlug/releases"
            }
        } catch {}
    } catch { }   # offline / rate limit / GitHub недоступен - просто молчим
}
Check-Updates

function Confirm-It([string]$Text) {
    $r = Read-Host "$Text (да/нет)"
    return ($r -match '^(д|да|y|yes)$')
}

function Run-Step([string]$Label, [scriptblock]$Body) {
    Write-Host "`n--- $Label ---" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    & $Body
    if ($LASTEXITCODE -eq 0) {
        Write-Host '[OK] Готово' -ForegroundColor Green
    } else {
        Write-Host "[!] Скрипт завершился с ошибкой (код $LASTEXITCODE). Если не помогло - пункт [8] Диагностика." -ForegroundColor Red
    }
    Read-Host 'Нажми Enter, чтобы вернуться в меню' | Out-Null
}

function Show-Menu {
    Clear-Host
    Write-Host "=========================================================="
    Write-Host "           MG Helper - by Bayra & Kavel1n"
    Write-Host "=========================================================="

    # status header
    $cfg = Resolve-MgPaths -NoSave
    $installed = Test-Path (Join-Path $HelperDir 'gta-settings-watcher.ps1')
    $watchAlive = @(Get-WatcherProcess -ExcludePid $PID).Count -gt 0
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
    Write-Host "  MG Helper v$script:PkgVersion - by Bayra & Kavel1n"
    Write-Host ""
    Write-Host "  [1] Установка          (запустить один раз)"
    Write-Host "  [2] Reset settings     (текущие настройки станут защищёнными)"
    Write-Host "  [3] Import settings    (импорт settings.xml из этой папки)"
    Write-Host "  [4] MAX FPS            (экстремальный профиль производительности)"
    Write-Host "  [5] Отключить тени     (максимальный FPS)"
    Write-Host "  [6] Очистка кэша       (ВНИМАНИЕ: перекачка десятков ГБ)"
    Write-Host ""
    Write-Host "  [7] Восстановить MG    (вернуть настройки MG из снапшота)"
    Write-Host "  [8] Диагностика + отчёт (если что-то не работает)"
    Write-Host "  [9] Repair              (исправить типовые проблемы)"
    Write-Host "  [10] Удалить всё"
    Write-Host "  [11] Новый эталон       (после смены GPU/обновления игры)"
    Write-Host "  [12] Проверить обновления (скачать + SHA256 + установить)"
    Write-Host "  [13] История эталона    (undo - вернуть прошлую версию)"
    Write-Host "  [14] Применить свой профиль"
    Write-Host "  [15] Сохранить текущие как профиль"
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
        '7' { Run-Step "Restore MG snapshot" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'restore-mg-snapshot.ps1') } }
        '8' { Run-Step "Diagnose" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'diagnose.ps1') } }
        '9' { Run-Step "Repair" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'repair.ps1') } }
        '10' {
            if (Confirm-It 'Удалить watcher и автозапуск? Бэкапы и эталон останутся.') {
                & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'uninstall.ps1')
                # REVIEW-#20: never claim success when the uninstall failed
                if ($LASTEXITCODE -eq 0) {
                    Write-Host ''
                    Write-Host 'Удалено. Эту папку можно удалить.'
                    Read-Host 'Нажми Enter для выхода'
                    exit 0
                }
                Write-Host '[!] Удаление завершилось с ошибками - см. сообщения выше. Программа НЕ удалена полностью.' -ForegroundColor Red
                Read-Host 'Нажми Enter, чтобы вернуться в меню'
            }
        }
        '11' {
            Run-Step 'Новый эталон (сменилась игра/GPU)' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'reset-settings.ps1') }
        }
        '12' {
            Run-Step 'Проверить обновления' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'update-helper.ps1') }
        }
        '13' {
            Run-Step 'История эталона (undo)' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'restore-golden-history.ps1') }
        }
        '14' {
            Run-Step 'Применить свой профиль' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'apply-custom-profile.ps1') }
        }
        '15' {
            Run-Step 'Сохранить текущие как профиль' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'save-custom-profile.ps1') }
        }
        '0' { exit 0 }
        default {
            Write-Host "Нет такого пункта. Введи цифру 0-10." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}
