# MG Helper menu - by Bayra & Kavel1n
$host.UI.RawUI.WindowTitle = 'MG Helper - by Bayra & Kavel1n'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = $PSScriptRoot

# MG3-007 / CONTRACT-2.6.1 §6: широкое снятие Mark-of-the-Web убрано. Оно
# снимало метку со ВСЕХ файлов пакета при каждом запуске меню, ничего не
# проверяя. Заблокированный ZIP пользователь разблокирует сам (Properties ->
# "Разблокировать") или это делает установщик точечно для своих файлов.

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
        New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null-
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

function Restart-Watcher {
    # CONTRACT-2.6.1 §6: после нового эталона (пункты [11]/[2]) watcher обязан
    # перечитать settings.golden.xml и golden_key.json - иначе он остаётся в
    # SAFE MODE до перезапуска. Best-effort: нет события/задачи (не установлен,
    # старый пакет) - просто выходим, меню не падает.
    # Сообщение честное: Start-ScheduledTask при живом старом экземпляре
    # (MultipleInstances=IgnoreNew) молча ничего не делает, поэтому "перезапущен"
    # печатается только когда старый watcher действительно ушёл.
    try {
        $aliveBefore = 0
        if (Get-Command Get-WatcherProcess -ErrorAction SilentlyContinue) {
            try { $aliveBefore = @(Get-WatcherProcess -ExcludePid $PID).Count } catch { $aliveBefore = 0 }
        }

        $signalled = $false
        try {
            $stopEvent = [System.Threading.EventWaitHandle]::OpenExisting('Local\MG_Helper_Stop')
            try { $signalled = $stopEvent.Set() } finally { $stopEvent.Dispose() }
        } catch { $signalled = $false }
        # 2.6.1: резервный канал - файл stop.request. Именованное событие может быть
        # недоступно (другая сессия, политика объектов) - на живой машине так и было:
        # событие не открывалось, и перезапуск после [11] не срабатывал.
        if (-not $signalled -and $aliveBefore -gt 0) {
            try {
                $flag = Join-Path (Join-Path $env:LOCALAPPDATA 'MG_Helper') 'stop.request'
                [IO.File]::WriteAllText($flag, "requested=$(Get-Date -Format 'o')", [Text.UTF8Encoding]::new($false))
                $signalled = $true
            } catch { }
        }

        $oldGone = ($aliveBefore -eq 0)
        if ($signalled) {
            # ждём до 7 с, пока старый watcher выйдет и освободит mutex
            $deadline = (Get-Date).AddSeconds(7)
            while ((Get-Date) -lt $deadline) {
                $alive = $false
                if (Get-Command Get-WatcherProcess -ErrorAction SilentlyContinue) {
                    try { $alive = @(Get-WatcherProcess -ExcludePid $PID).Count -gt 0 } catch { $alive = $false }
                } else {
                    Start-Sleep -Milliseconds 500
                    break
                }
                if (-not $alive) { $oldGone = $true; break }
                Start-Sleep -Milliseconds 500
            }
        }

        Start-ScheduledTask -TaskName 'MG_Helper_Watcher' -ErrorAction Stop

        if (-not $signalled -and $aliveBefore -gt 0) {
            Write-Host '[!] Старый watcher жив, а канал остановки недоступен - перезапуск не гарантирован. Пункт [1] или [9].' -ForegroundColor Yellow
        } elseif ($signalled -and (-not $oldGone)) {
            Write-Host '[!] Старый watcher не завершился за 7 с - перезапуск не гарантирован. Пункт [1] или [9].' -ForegroundColor Yellow
        } else {
            Write-Host '[i] Watcher перезапущен - новый эталон подхвачен.' -ForegroundColor DarkGray
        }
    } catch {
        Write-Host '[i] Watcher не перезапущен автоматически (задача не установлена?) - пункт [1] или [9].' -ForegroundColor DarkGray
    }
}

function Show-Menu {
    Clear-Host
    Write-Host "=========================================================="
    Write-Host "           MG Helper - by Bayra & Kavel1n"
    Write-Host "=========================================================="

    # status header
    $cfg = Resolve-MgPaths -NoSave
    $installed = Test-Path (Join-Path $HelperDir 'gta-settings-watcher.ps1')
    $script:menuInstalled = $installed
    # CONTRACT-2.6.1 §6: статус watcher'а - из watcher.health.json (свежесть
    # heartbeat), а не из "процесс существует". Нет функции/файла (старый
    # common.ps1, свежая установка) - прежнее поведение по процессу.
    $watchHealth = $null
    if (Get-Command Get-WatcherHealth -ErrorAction SilentlyContinue) {
        try { $watchHealth = Get-WatcherHealth } catch { $watchHealth = $null }
    }
    $watchState = if ($watchHealth -and $watchHealth.status) { [string]$watchHealth.status } else { $null }
    # legacy fallback (no health function / old common.ps1): process presence only
    $watchAlive = $false
    if (Get-Command Get-WatcherProcess -ErrorAction SilentlyContinue) {
        try { $watchAlive = @(Get-WatcherProcess -ExcludePid $PID).Count -gt 0 } catch { $watchAlive = $false }
    }
    $mgOk = $cfg.miamiGraphicsDir -and (Test-Path -LiteralPath $cfg.miamiGraphicsDir)
    $sxOk = $cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)

    Write-Host ""
    Write-Host "  Установка:    " -NoNewline
    if ($installed) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "не установлена - начни с пункта [1]" -ForegroundColor Red }
    Write-Host "  Ватчер:       " -NoNewline
    if ($watchState -eq 'Healthy') {
        Write-Host "работает (heartbeat свежий)" -ForegroundColor Green
    } elseif ($watchState -eq 'Degraded') {
        $ageTxt = if ($null -ne $watchHealth.ageSec) { ' ({0:N0} с)' -f [double]$watchHealth.ageSec } else { '' }
        Write-Host "не отвечает$ageTxt" -ForegroundColor Yellow
    } elseif ($watchState -eq 'Stopped') {
        if ($installed) { Write-Host "НЕ РАБОТАЕТ - пункт [9] Repair" -ForegroundColor Red }
        else { Write-Host "не установлен - начни с пункта [1]" -ForegroundColor DarkGray }
    } elseif ($watchState -eq 'Unknown') {
        if ($installed) { Write-Host "статус неизвестен (нет/битый watcher.health.json) - пункт [9]" -ForegroundColor Yellow }
        else { Write-Host "не установлен - начни с пункта [1]" -ForegroundColor DarkGray }
    } elseif ($watchAlive) {
        Write-Host "работает" -ForegroundColor Green
    } else {
        Write-Host "не запущен" -ForegroundColor $(if ($installed) { 'Yellow' } else { 'DarkGray' })
    }
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

# ROADMAP 5.5: onboarding wizard - shown ONCE on the first run before install
function Show-Onboarding {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Первый запуск MG Helper - быстрый мастер" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Как это работает (одна картинка словами):"
    Write-Host "    1. Пока игра запущена, эталон защищается ВСЮ сессию:"
    Write-Host "       чужие перезаписи настроек откатываются к твоему эталону."
    Write-Host "    2. Эталон - это настройки, снятые тобой в меню [2] или [11]."
    Write-Host "    3. При выходе из игры эталон возвращается на диск: правки,"
    Write-Host "       сделанные в игре, по умолчанию НЕ становятся эталоном."
    Write-Host "       Хочешь сохранять свои правки из игры - включи"
    Write-Host "       allowAdopt: true в config.json (подробности - README)."
    Write-Host ""
    $components = @()
    if ($cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)) { $components += "settings.xml найден" } else { $components += "settings.xml НЕ найден" }
    if ($cfg.miamiGraphicsDir -and (Test-Path -LiteralPath $cfg.miamiGraphicsDir)) { $components += "Miami Graphics найден" } else { $components += "Miami Graphics не найден" }
    Write-Host "  Обнаружено на этом ПК:"
    foreach ($c in $components) { Write-Host "    - $c" }
    Write-Host ""
    $ans = Read-Host "Установить защиту сейчас? (да/нет)"
    if ($ans -match '^(д|да|y|yes)$') {
        Run-Step "Установка" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install-gta-watcher.ps1') }
        Write-Host "  Готово! Дальше просто играй. Иконка в трее покажет статус." -ForegroundColor Green
        Write-Host "  Если сменишь видеокарту или игру обновят - меню [11]." -ForegroundColor DarkGray
    } else {
        Write-Host "  Мастер закрыт. Установить позже - пункт [1]." -ForegroundColor DarkGray
    }
}
$script:onboardingShown = $false

while ($true) {
    Show-Menu
    if (-not $script:menuInstalled -and (-not $script:onboardingShown)) {
        $script:onboardingShown = $true
        Show-Onboarding
        Show-Menu
    }
    $choice = Read-Host "Выбери пункт"
    switch ($choice) {
        '1' { Run-Step "Установка" { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install-gta-watcher.ps1') } }
        '2' {
            Run-Step "Reset settings" {
                & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'reset-settings.ps1')
                Restart-Watcher   # CONTRACT-2.6.1 §6: новый эталон -> watcher перечитывает golden + ключ
            }
        }
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
            Run-Step 'Новый эталон (сменилась игра/GPU)' {
                & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'reset-settings.ps1')
                Restart-Watcher   # CONTRACT-2.6.1 §6: новый эталон -> watcher перечитывает golden + ключ
            }
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
