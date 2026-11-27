# Locates the deployed watcher and runs its -Diagnose mode.
# Used as source for 5-diagnose.bat (EncodedCommand).
# by Bayra & Kavel1n
param([switch]$NoOpenReport)   # -NoOpenReport: не открывать Проводник (тесты/автоматизация)
$host.UI.RawUI.WindowTitle = 'MG Helper Diagnose - by Bayra & Kavel1n'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$roots = @(
    "$env:LOCALAPPDATA\MG_Helper",
    "$env:USERPROFILE\Documents\Rockstar Games\GTA V\_settings_backup",
    "$env:USERPROFILE\OneDrive\Documents\Rockstar Games\GTA V\_settings_backup"
)
foreach ($one in (Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
    $roots += (Join-Path $one.FullName 'Documents\Rockstar Games\GTA V\_settings_backup')
}

$found = $null
foreach ($r in ($roots | Select-Object -Unique)) {
    $wp = Join-Path $r 'gta-settings-watcher.ps1'
    if (Test-Path $wp) { $found = $wp; break }
}

if (-not $found) {
    Write-Host "[!] Watcher not found on this PC." -ForegroundColor Red
    Write-Host "    Run MG-Helper.bat -> [1] first (it installs the watcher)."
    Write-Host ""
    Write-Host "Searched:"
    $roots | ForEach-Object { Write-Host "    $_" }
    exit 1
}

Write-Host "[i] Watcher found: $found"
Write-Host "=================================================="

# capture diagnose output: shown on screen AND saved to a report bundle ready to send
$watcherDir = Split-Path $found
$rep = & powershell -NoProfile -ExecutionPolicy Bypass -File $found -Diagnose 2>&1

# ------------------------------------------------------------
# ПРОВЕРКИ diagnose.ps1 - контракт 2.6.1 п.6.
# Раньше отчёт мог объявить "Всё в порядке", ничего не проверив: живость
# watcher'а определялась по возрасту watcher.log внутри самого watcher'а
# (-Diagnose), задача - только на существование, а TextureQuality/CityDensity
# брались из ЭТАЛОНА, а не из живых настроек игры. Теперь проверяем реально:
#   * watcher.health.json (свежесть heartbeat) через Get-WatcherHealth;
#   * живой settings.xml против эталона через Test-SameSettings (три состояния);
#   * задачу автозапуска - существование И состояние;
# и печатаем "Всё в порядке" только когда все проверки действительно пройдены.
# ------------------------------------------------------------
$commonPath = Join-Path $watcherDir 'common.ps1'
if (Test-Path -LiteralPath $commonPath) { . $commonPath }

$script:checks = @()
function Add-Check([string]$Level, [string]$Text) { $script:checks += [pscustomobject]@{ level = $Level; text = $Text } }

function Read-HealthLocal([string]$Path) {
    # запасной разбор watcher.health.json (если common.ps1 младше 2.6.1):
    # правила свежести из контракта, время сравнивается в UTC
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ status = 'Unknown'; data = $null; ageSec = $null; note = 'файла нет' } }
    $d = $null
    try { $d = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { return [pscustomobject]@{ status = 'Unknown'; data = $null; ageSec = $null; note = 'JSON не читается' } }
    $hb = $null
    try { if ($d.lastHeartbeatUtc) { $hb = ([datetime]$d.lastHeartbeatUtc).ToUniversalTime() } } catch {}
    if (-not $hb) { return [pscustomobject]@{ status = 'Unknown'; data = $d; ageSec = $null; note = 'нет метки времени' } }
    $age = ((Get-Date).ToUniversalTime() - $hb).TotalSeconds
    if ($d.status -eq 'stopping') { return [pscustomobject]@{ status = 'Stopped'; data = $d; ageSec = $age; note = 'status=stopping' } }
    # контракт 2.6.1: status=starting - ещё не Healthy, даже при свежем heartbeat
    if ($age -le 15 -and $d.status -ne 'starting') { return [pscustomobject]@{ status = 'Healthy'; data = $d; ageSec = $age; note = '' } }
    if ($age -le 30) { return [pscustomobject]@{ status = 'Degraded'; data = $d; ageSec = $age; note = $(if ($d.status -eq 'starting') { 'status=starting' } else { 'heartbeat просрочен' }) } }
    return [pscustomobject]@{ status = 'Stopped'; data = $d; ageSec = $age; note = 'heartbeat старше 30 c' }
}

# --- 1. watcher: watcher.health.json ---
$healthPath = Join-Path $watcherDir 'watcher.health.json'
$health = $null
$healthFrom = 'разбор watcher.health.json внутри diagnose.ps1'
if (Get-Command Get-WatcherHealth -ErrorAction SilentlyContinue) {
    try { $health = Get-WatcherHealth } catch { $health = $null }
    if ($health) { $healthFrom = 'Get-WatcherHealth (common.ps1)' }
}
if (-not $health) { $health = Read-HealthLocal $healthPath }
# если consumer читает другой путь (HelperDir), показываем именно его
if (Get-Command Get-WatcherHealthPath -ErrorAction SilentlyContinue) {
    try { $hp2 = Get-WatcherHealthPath; if ($hp2) { $healthPath = $hp2 } } catch {}
}
$hStatus = if ($health.status) { [string]$health.status } else { 'Unknown' }
$hAge = $health.ageSec
$hd = $health.data
$hAgeTxt = if ($null -ne $hAge) { ('{0:N1} c' -f [double]$hAge) } else { 'нет данных' }
$hStatusField = if ($hd -and $hd.status) { [string]$hd.status } else { 'н/д' }
$hPhase = if ($hd -and $hd.phase) { [string]$hd.phase } else { 'н/д' }
$hPid = if ($hd -and $hd.pid) { [string]$hd.pid } else { 'н/д' }
# контракт 2.6.1: status=starting - Degraded, даже когда heartbeat свежий
# (Get-WatcherHealth из common.ps1 2.6.0/раннего 2.6.1 этого не различает)
if ($hStatus -eq 'Healthy' -and $hStatusField -eq 'starting') { $hStatus = 'Degraded' }
switch ($hStatus) {
    'Healthy'  { Add-Check 'ok' "Watcher: Healthy (status=$hStatusField, phase=$hPhase, pid=$hPid, heartbeat $hAgeTxt)   [источник: $healthPath через $healthFrom]" }
    'Degraded' { Add-Check 'warn' "Watcher: Degraded (status=$hStatusField, heartbeat $hAgeTxt - не подтверждает живость, phase=$hPhase)   [источник: $healthPath через $healthFrom]" }
    'Stopped'  { Add-Check 'bad' "Watcher: Stopped (heartbeat $hAgeTxt - старше 30 c, status в файле: $hStatusField) - защита не работает, смотри меню [9]   [источник: $healthPath через $healthFrom]" }
    default    { Add-Check 'warn' "Watcher: статус неизвестен - нет данных (файла нет или он битый; так выглядит watcher младше 2.6.1 либо упавший watcher)   [источник: $healthPath через $healthFrom]" }
}
# phase=UnknownSession = SAFE MODE: watcher жив, но защита выключена (инвариант 4)
if ($hPhase -eq 'UnknownSession' -and ($hStatus -eq 'Healthy' -or $hStatus -eq 'Degraded')) {
    Add-Check 'bad' "[ПРОБЛЕМА] watcher в SAFE MODE (phase=UnknownSession) - защита выключена, настройки не охраняются; причина в watcher.log   [источник: $healthPath]"
}

# --- 2. watcher: живой процесс ---
$wf = @()
$procFrom = 'CIM Win32_Process, Get-WatcherProcess'
if (Get-Command Get-WatcherProcess -ErrorAction SilentlyContinue) {
    try { $wf = @(Get-WatcherProcess -ExcludePid $PID) } catch { $wf = @() }
}
else {
    # common.ps1 нет или он старее 2.6.1: тот же фильтр локально, иначе проверка
    # "процесс не найден" была бы фиктивной
    $procFrom = 'CIM Win32_Process (локальный фильтр diagnose.ps1)'
    try {
        $wf = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -OperationTimeoutSec 15 -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'gta-settings-watcher\.ps1' -and $_.CommandLine -notmatch '-Diagnose' })
    } catch { $wf = @() }
}
if ($wf.Count -gt 0) {
    $wPids = ($wf | ForEach-Object { $_.ProcessId }) -join ', '
    Add-Check 'ok' "Процесс watcher: $($wf.Count) шт., PID $wPids   [источник: $procFrom]"
    # health-файл должен принадлежать ОДНОМУ из этих процессов, иначе он остался
    # от прошлого запуска и "Healthy" относится к мёртвому PID
    if ($hd -and $hd.pid) {
        $hPidNum = 0
        try { $hPidNum = [int]$hd.pid } catch { $hPidNum = 0 }
        if ($hPidNum -gt 0 -and -not (@($wf | ForEach-Object { [int]$_.ProcessId }) -contains $hPidNum)) {
            Add-Check 'warn' "Heartbeat watcher'а принадлежит PID $hPidNum, но такого watcher-процесса нет (живые: $wPids) - health-файл мог остаться от прошлого запуска   [источник: $healthPath + CIM Win32_Process]"
        }
    }
}
elseif ($hStatus -eq 'Healthy' -or $hStatus -eq 'Degraded') {
    Add-Check 'warn' "Процесс watcher не найден, хотя heartbeat свежий - health-файл мог остаться от прошлого запуска   [источник: $procFrom]"
}
else {
    Add-Check 'warn' "Процесс watcher не найден   [источник: $procFrom]"
}

# --- 3. задача автозапуска: существование И состояние ---
$taskName = 'MG_Helper_Watcher'
$task = $null
try { $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
if (-not $task) {
    Add-Check 'bad' "[ПРОБЛЕМА] задача автозапуска $taskName отсутствует - запусти пункт меню [9] Repair   [источник: планировщик задач]"
}
else {
    $tState = [string]$task.State
    $tInfo = $null
    try { $tInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
    $tLast = if ($tInfo) { [string]$tInfo.LastRunTime } else { 'н/д' }
    $tRes = if ($tInfo) { [string]$tInfo.LastTaskResult } else { 'н/д' }
    # 267009 = 0x41301 SCHED_S_TASK_RUNNING: "задача выполняется сейчас", это не ошибка
    $tResTxt = if ($tRes -eq '267009') { 'выполняется' } else { $tRes }
    if ($tState -eq 'Disabled') {
        Add-Check 'bad' "[ПРОБЛЕМА] задача автозапуска $taskName отключена (State=Disabled) - watcher не стартует   [источник: планировщик задач]"
    }
    else {
        Add-Check 'ok' "Задача ${taskName}: State=$tState, последний запуск $tLast, код $tResTxt   [источник: планировщик задач]"
        if ($tState -ne 'Running' -and ($tRes -ne '0') -and ($tRes -ne 'н/д')) {
            Add-Check 'warn' "Задача ${taskName}: код последнего завершения $tRes (не 0)   [источник: планировщик задач]"
        }
    }
}

# --- 4. живые настройки игры против эталона ---
$cfgFile = Join-Path $watcherDir 'config.json'
$cfg = $null
try { if (Test-Path -LiteralPath $cfgFile) { $cfg = Get-Content -LiteralPath $cfgFile -Raw -ErrorAction Stop | ConvertFrom-Json } } catch { $cfg = $null }
$settingsXml = if ($cfg) { [string]$cfg.settingsXml } else { '' }
$sxFrom = 'config.json -> settingsXml'
if (-not $settingsXml -or -not (Test-Path -LiteralPath $settingsXml)) {
    if (Get-Command Find-SettingsXml -ErrorAction SilentlyContinue) {
        try { $f = Find-SettingsXml; if ($f) { $settingsXml = $f; $sxFrom = 'common.ps1 Find-SettingsXml (config.json путь не дал)' } } catch {}
    }
}
$helperDir = if ($script:HelperDir) { $script:HelperDir } else { $watcherDir }
$golden = Join-Path $helperDir 'settings.golden.xml'
$goldenOk = $false
if (Get-Command Test-GoldenValid -ErrorAction SilentlyContinue) {
    try { $goldenOk = [bool](Test-GoldenValid $golden) } catch { $goldenOk = $false }
}
else {
    try { $goldenOk = (Test-Path -LiteralPath $golden) -and ((Get-Item -LiteralPath $golden).Length -gt 100) } catch { $goldenOk = $false }
}

$hasLive = [bool]($settingsXml -and (Test-Path -LiteralPath $settingsXml))
if ($hasLive) { Add-Check 'ok' "Живые настройки игры: $settingsXml   [источник: $sxFrom]" }
else { Add-Check 'bad' "[ПРОБЛЕМА] живые настройки игры (settings.xml) не найдены - запусти GTA V один раз   [источник: $sxFrom]" }
if ($goldenOk) { Add-Check 'ok' "Эталон: $golden (валиден)   [источник: файл эталона]" }
else { Add-Check 'bad' "[ПРОБЛЕМА] эталон отсутствует или повреждён ($golden) - запусти меню [2] Reset settings   [источник: файл эталона]" }

$same = $null
$sameFrom = 'Test-SameSettings (common.ps1)'
if ($hasLive -and $goldenOk) {
    if (Get-Command Test-SameSettings -ErrorAction SilentlyContinue) {
        try { $same = Test-SameSettings $settingsXml $golden } catch { $same = $null }
    }
    else {
        # запасной путь: без common.ps1 сравниваем текст без пробелов
        $sameFrom = 'сравнение текста без пробелов (в diagnose.ps1; common.ps1 без Test-SameSettings)'
        try {
            $a = [IO.File]::ReadAllText($settingsXml)
            $b = [IO.File]::ReadAllText($golden)
            $same = (($a -replace '\s+', '') -eq ($b -replace '\s+', ''))
        } catch { $same = $null }
    }
}
if ($null -eq $same) {
    if ($hasLive -and $goldenOk) {
        Add-Check 'warn' "Живые настройки == эталон: НЕ ПРОВЕРЕНО - файл не читается (занят игрой?)   [источник: $sameFrom]"
    }
    else {
        Add-Check 'warn' "Живые настройки == эталон: НЕ ПРОВЕРЕНО - нет файла настроек или эталона   [источник: $sameFrom]"
    }
}
elseif ($same) {
    Add-Check 'ok' "Живые настройки == эталон: да   [источник: $sameFrom; файлы settings.xml и settings.golden.xml]"
}
else {
    Add-Check 'bad' "[ПРОБЛЕМА] живые настройки ОТЛИЧАЮТСЯ от эталона - защищённые настройки не на диске (включён adopt в config.json? иначе эталон должен был вернуться при выходе)   [источник: $sameFrom]"
}

# TextureQuality/CityDensity - из ЖИВЫХ настроек; значения эталона помечаются отдельно
$tqLive = $null
$cdLive = $null
$liveReadOk = $false
if ($hasLive) {
    try {
        $liveText = [IO.File]::ReadAllText($settingsXml)
        $liveReadOk = $true
        $tqLive = ([regex]::Match($liveText, '<TextureQuality value="([^"]+)"')).Groups[1].Value
        $cdLive = ([regex]::Match($liveText, '<CityDensity value="([^"]+)"')).Groups[1].Value
    } catch { $liveReadOk = $false }
}
if ($liveReadOk) {
    Add-Check 'ok' "TextureQuality (ЖИВЫЕ настройки): $tqLive   [источник: $settingsXml]"
    Add-Check 'ok' "CityDensity (ЖИВЫЕ настройки): $cdLive   [источник: $settingsXml]"
}
elseif ($hasLive) {
    Add-Check 'warn' "TextureQuality/CityDensity: живые настройки не читаются (файл занят игрой) - значения не проверены   [источник: $settingsXml]"
}
if ($goldenOk) {
    try {
        $goldenText = [IO.File]::ReadAllText($golden)
        $tqG = ([regex]::Match($goldenText, '<TextureQuality value="([^"]+)"')).Groups[1].Value
        $cdG = ([regex]::Match($goldenText, '<CityDensity value="([^"]+)"')).Groups[1].Value
        Add-Check 'ok' "Значения ЭТАЛОНА (для сравнения): TextureQuality=$tqG, CityDensity=$cdG   [источник: $golden]"
    } catch {}
}

# --- 5. итог: "Всё в порядке" только когда проверки пройдены ---
$badN = @($script:checks | Where-Object { $_.level -eq 'bad' }).Count
$warnN = @($script:checks | Where-Object { $_.level -eq 'warn' }).Count
$okN = @($script:checks | Where-Object { $_.level -eq 'ok' }).Count
if ($badN -gt 0) {
    $verdict = "НЕ ПОДТВЕРЖДЕНО - проблем: $badN, предупреждений: $warnN (проверок пройдено: $okN). Смотри строки [ПРОБЛЕМА] выше."
    $verdictLevel = 'bad'
}
elseif ($warnN -gt 0) {
    $verdict = "проверено не всё - предупреждений: $warnN (проверок пройдено: $okN). Защита не подтверждена, смотри строки [ВНИМАНИЕ] выше."
    $verdictLevel = 'warn'
}
else {
    $verdict = "Всё в порядке - проверки пройдены ($okN): watcher Healthy, процесс запущен, задача автозапуска на месте, живые настройки совпадают с эталоном."
    $verdictLevel = 'ok'
}

# встроенный вердикт watcher -Diagnose не включает этих проверок: если они нашли
# проблему/непроверенное, снимаем его "Всё в порядке", чтобы отчёт не противоречил сам себе
if ($badN -gt 0 -or $warnN -gt 0) {
    $rep = @($rep | ForEach-Object {
        $line = "$_"
        if ($line -match 'Всё в порядке') { $line = '  (вердикт встроенной диагностики watcher снят: она не проверяет watcher.health.json и живой settings.xml - смотри ПРОВЕРКИ diagnose.ps1)' }
        $line
    })
}
$rep | ForEach-Object { $_.ToString() } | Write-Host

Write-Host ""
Write-Host "=== ПРОВЕРКИ diagnose.ps1 ===" -ForegroundColor Cyan
foreach ($c in $script:checks) {
    $col = switch ($c.level) { 'bad' { 'Red' } 'warn' { 'Yellow' } default { 'Green' } }
    Write-Host ("  {0}" -f $c.text) -ForegroundColor $col
}
$vcol = switch ($verdictLevel) { 'bad' { 'Red' } 'warn' { 'Yellow' } default { 'Green' } }
Write-Host ("ИТОГ: {0}" -f $verdict) -ForegroundColor $vcol

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$header = "MG Helper diagnostic report - $stamp - by Bayra & Kavel1n"
$header + "`r`n" + (($rep | ForEach-Object { $_.ToString() }) -join "`r`n") |
    Out-File (Join-Path $watcherDir "report_$stamp.txt") -Encoding UTF8

# enrich the report: config, longer log, snapshot list, archive listing, versions
$extra = @()
$extra += ""
$extra += "=== ПРОВЕРКИ diagnose.ps1 (watcher / настройки / задача) ==="
foreach ($c in $script:checks) {
    $mark = switch ($c.level) { 'bad' { '[ПРОБЛЕМА]' } 'warn' { '[ВНИМАНИЕ]' } default { '[ok]' } }
    $extra += ("{0} {1}" -f $mark, $c.text)
}
$extra += "ИТОГ: $verdict"
$diskLines = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
    ForEach-Object { "Диск $($_.DeviceID) свободно: $([int]($_.FreeSpace / 1GB)) ГБ" })
if ($diskLines.Count -eq 0) { $diskLines = @("Диск C свободно: $([int]((Get-PSDrive C -ErrorAction SilentlyContinue).Free / 1GB)) ГБ") }
$extra += ""
$extra += "=== ОКРУЖЕНИЕ ==="
$extra += "Watcher: $found"
$extra += "OS:     $([Environment]::OSVersion.VersionString)"
$extra += "PS:     $($PSVersionTable.PSVersion)"
$extra += $diskLines
$extra += ""
$extra += "=== CONFIG.JSON (ключи и версии; пути маскируются) ==="
$extra += (Get-Content (Join-Path $watcherDir 'config.json') -Raw -ErrorAction SilentlyContinue)
$extra += ""
$extra += "=== СОБЫТИЯ (events.jsonl, последние 20) ==="
$extra += (Get-Content (Join-Path $watcherDir 'events.jsonl') -Tail 20 -ErrorAction SilentlyContinue)
$extra += ""
$extra += "=== WATCHER.LOG (последние 40 строк) ==="
$extra += (Get-Content (Join-Path $watcherDir 'watcher.log') -Tail 40 -ErrorAction SilentlyContinue)
$extra += ""
$extra += "=== MG SNAPSHOT ==="
$extra += (Get-ChildItem (Join-Path $watcherDir 'mg_snapshot') -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($($_.Length) байт)" })
$extra += ""
$extra += "=== VANILLA BACKUP ARCHIVE ==="
$extra += (Get-ChildItem (Join-Path $watcherDir 'vanilla_backup_archive') -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($([int]($_.Length / 1MB)) МБ)" })
$extra | Add-Content (Join-Path $watcherDir "report_$stamp.txt") -Encoding UTF8

# MG-CR-011: the report goes to strangers - mask the user's identity by default.
# Full paths are opt-in with explicit confirmation. Applied to the WHOLE file
# (including the watcher -Diagnose header) by post-processing.
$mask = $true
Write-Host ""
$fullAnswer = Read-Host "Включить в отчёт ПОЛНЫЕ пути (содержат имя пользователя)? (да/нет)"
if ($fullAnswer -match '^(д|да|y|yes)$') { $mask = $false }
$reportPath = Join-Path $watcherDir "report_$stamp.txt"
if ($mask) {
    $rp = (Resolve-Path -LiteralPath $reportPath -ErrorAction SilentlyContinue).Path
    if ($rp) {
        $content = Get-Content -LiteralPath $rp -Raw -ErrorAction SilentlyContinue
        # пустое значение = regex '' совпал бы с каждой позицией и изуродовал отчёт
        if ($env:USERPROFILE) { $content = $content -replace [regex]::Escape($env:USERPROFILE), 'C:\Users\<USER>' }
        if ($env:USERDOMAIN -and $env:USERNAME) { $content = $content -replace [regex]::Escape($env:USERDOMAIN + '\' + $env:USERNAME), '<USER>' }
        if ($env:USERNAME) { $content = $content -replace [regex]::Escape($env:USERNAME), '<USER>' }
        [IO.File]::WriteAllText($rp, $content, [Text.UTF8Encoding]::new($true))
    }
}

Write-Host "=================================================="
Write-Host "[+] Report saved: report_$stamp.txt (in the watcher folder)" -ForegroundColor Green
Write-Host "    Send that FILE (not a screenshot) to Bayra / Kavel1n." -ForegroundColor Green
if ($mask) { Write-Host "[i] Персональные пути замаскированы (C:\Users\<USER>)." -ForegroundColor DarkGray }
else { Write-Host "[i] ВНИМАНИЕ: отчёт содержит ПОЛНЫЕ пути с именем пользователя." -ForegroundColor Yellow }
# open Explorer with the report file selected
if (-not $NoOpenReport) { Start-Process explorer.exe "/select,`"$watcherDir\report_$stamp.txt`"" }
