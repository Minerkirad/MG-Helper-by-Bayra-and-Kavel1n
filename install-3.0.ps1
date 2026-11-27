# install-3.0.ps1 - установщик MG Helper 3.0 (InstallRoot/DataRoot, версионные каталоги)
# by Bayra & Kavel1n
#
# Раскладка (docs/adr/ADR-002):
#   InstallRoot = <LOCALAPPDATA>\MG_Helper\App
#     Versions\<ver>\            неизменяемый каталог версии (скрипты, exe, манифест)
#     current.json              {"version","path","updated"} - переключается атомарно
#   DataRoot    = <LOCALAPPDATA>\MG_Helper   (не меняется: конфиг, эталон, state, журналы)
#
# Свойства: staged deploy (.incomplete -> verify manifest -> rename), манифест с SHA256,
# запрет отката на старую версию без -Force, миграционный отчёт, откат переключением
# указателя (без переустановки). Пользовательские данные не перемещаются и не удаляются.
#
#   .\install-3.0.ps1                  # обычная установка/обновление
#   .\install-3.0.ps1 -NoStart         # без регистрации задачи и запуска (тесты)
#   .\install-3.0.ps1 -SkipCompile     # не компилировать exe (тесты раскладки)
#   .\install-3.0.ps1 -Rollback        # переключить current.json на предыдущую версию
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$NoStart,
    [switch]$SkipCompile,
    [switch]$Rollback,
    [string]$DataRoot,
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
$pkg = $PSScriptRoot
. (Join-Path $pkg 'common.ps1')

if (-not $DataRoot) {
    $DataRoot = if ($env:MG_HELPER_DIR) { $env:MG_HELPER_DIR } else { Join-Path $env:LOCALAPPDATA 'MG_Helper' }
}
if (-not $InstallRoot) {
    $InstallRoot = if ($env:MG_INSTALL_ROOT) { $env:MG_INSTALL_ROOT } else { Join-Path $DataRoot 'App' }
}
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$versionsDir = Join-Path $InstallRoot 'Versions'
$currentFile = Join-Path $InstallRoot 'current.json'
$taskName = 'MG_Helper_Watcher'

function Write-Step([string]$Text) { Write-Host "[*] $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "[+] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "[!] $Text" -ForegroundColor Yellow }

$packageVersion = '0.0.0'
try { $packageVersion = [string](Get-Content -LiteralPath (Join-Path $pkg 'version.json') -Raw | ConvertFrom-Json).version } catch { }

# ---------------- guards ----------------
$liveVersion = $null
try { $liveVersion = [string](Get-Content -LiteralPath (Join-Path $DataRoot 'version.json') -Raw | ConvertFrom-Json).version } catch {}
if ((Test-InstallDowngrade -LiveVersion $liveVersion -PackageVersion $packageVersion) -and -not $Force) {
    Write-Warn2 "в DataRoot уже стоит версия $liveVersion, а пакет - $packageVersion."
    Write-Warn2 'Затирать более новую установку старым пакетом нельзя. Осознанный откат: -Force.'
    exit 1
}
if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null }
New-Item -ItemType Directory -Force -Path $versionsDir | Out-Null

$actions = New-Object System.Collections.Generic.List[string]

function Write-Current([string]$Version) {
    $json = [ordered]@{
        version = $Version
        path    = "Versions\$Version"
        updated = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 3
    if (-not (Write-Atomic -Path $currentFile -Bytes ([Text.Encoding]::UTF8.GetBytes($json)))) {
        throw "не удалось записать $currentFile"
    }
}

function Stop-WatcherForInstall {
    # тестовый режим (MG_INSTALL_ROOT): не трогаем живые процессы и задачу
    if ($env:MG_INSTALL_ROOT) { $null = $actions.Add('watcher: тестовый режим, остановка пропущена'); return }
    if (Get-Command Invoke-MgPipeCommand -ErrorAction SilentlyContinue) {
        $r = Invoke-MgPipeCommand -Command 'stop' -TimeoutMs 1200
        if ($r -and $r.ok) { $null = $actions.Add('watcher: остановлен через канал') }
    }
    try { [IO.File]::WriteAllText((Join-Path $DataRoot 'stop.request'), (Get-Date).ToUniversalTime().ToString('o'), [Text.UTF8Encoding]::new($false)) } catch {}
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='MGHelper.Watcher.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -match 'gta-settings-watcher|MGHelper\.Watcher' })
        if ($alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 400
    }
    if (-not $NoStart) {
        try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
    }
    Write-Step 'старый watcher остановлен (если работал)'
}

# ---------------- rollback: switch the pointer only ----------------
if ($Rollback) {
    if (-not (Test-Path -LiteralPath $versionsDir)) { Write-Warn2 "нет каталога версий: $versionsDir"; exit 1 }
    $current = $null
    try { $current = (Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json).version } catch { }
    $available = @(Get-ChildItem $versionsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.incomplete' } | Sort-Object Name -Descending)
    if ($available.Count -eq 0) { Write-Warn2 'нет установленных версий для отката'; exit 1 }
    $target = $available | Where-Object { $_.Name -ne $current } | Select-Object -First 1
    if (-not $target) { Write-Warn2 "откатываться некуда (установлена только $current)"; exit 1 }
    Stop-WatcherForInstall
    Write-Current $target.Name
    Write-Ok "current.json переключён на $($target.Name) (было $current)"
    exit 0
}


# ---------------- deploy list ----------------
$deploy = @(
    'common.ps1', 'MgHelper.Core.ps1', 'gta-settings-watcher.ps1', 'MG-Helper.ps1', 'MG-Helper.bat',
    'diagnose.ps1', 'uninstall.ps1', 'repair.ps1', 'reset-settings.ps1', 'import-settings.ps1',
    'clean-majestic-cache.ps1', 'max-fps.ps1', 'cut-shadows.ps1', 'restore-mg-snapshot.ps1',
    'restore-golden-history.ps1', 'save-custom-profile.ps1', 'apply-custom-profile.ps1',
    'update-helper.ps1', 'install-gta-watcher.ps1', 'install-3.0.ps1',
    'CoreDecisions.cs', 'HelperPipe.cs', 'MGHelper.Watcher.cs', 'MGCore.cs',
    'MG-Helper-Host.cs', 'MG-Helper-Tray.cs', 'version.json'
)

$versionDir = Join-Path $versionsDir $packageVersion
$staging = Join-Path $versionsDir ($packageVersion + '.incomplete')
Write-Step "staged deploy $packageVersion -> $staging"
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
foreach ($file in $deploy) {
    $src = Join-Path $pkg $file
    if (-not (Test-Path -LiteralPath $src)) { continue }
    Copy-Item -LiteralPath $src -Destination (Join-Path $staging $file) -Force
}
if (-not $SkipCompile) {
    Write-Step 'компиляция exe (host, трей, ядро, watcher)'
    & (Join-Path $pkg 'tools\build-core.ps1') -OutputDir $staging -Force | Out-Null
    $hostExe = Join-Path $staging 'MG-Helper-Host.exe'
    if (Test-Path -LiteralPath $hostExe) { $null = (Get-Item $hostExe) }
}

# ---------------- manifest + verify ----------------
Write-Step 'манифест и проверка'
$manifest = [ordered]@{}
Get-ChildItem $staging -File | Sort-Object Name | ForEach-Object {
    $manifest[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
}
$manifestJson = [ordered]@{ schema = 1; version = $packageVersion; created = (Get-Date).ToUniversalTime().ToString('o'); files = $manifest } | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $staging 'manifest.json'), $manifestJson, [Text.UTF8Encoding]::new($false))
$manifestCheck = Get-Content -LiteralPath (Join-Path $staging 'manifest.json') -Raw | ConvertFrom-Json
$problems = @()
foreach ($prop in $manifestCheck.files.PSObject.Properties) {
    $path = Join-Path $staging $prop.Name
    if (-not (Test-Path -LiteralPath $path)) { $problems += "нет файла $($prop.Name)"; continue }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne $prop.Value) { $problems += "хэш не совпал: $($prop.Name)" }
}
if ($problems.Count -gt 0) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    throw ("манифест не подтверждён: " + ($problems -join '; '))
}

# ---------------- promote ----------------
Write-Step 'promotion (incomplete -> version)'
if (Test-Path -LiteralPath $versionDir) { Remove-Item -LiteralPath $versionDir -Recurse -Force -ErrorAction SilentlyContinue }
Move-Item -LiteralPath $staging -Destination $versionDir -Force
$null = $actions.Add("deploy: $packageVersion -> $versionDir")

Stop-WatcherForInstall
Write-Current $packageVersion
$null = $actions.Add("current.json -> $packageVersion")

# DataRoot: обновляем только маркер версии, пользовательские файлы не трогаем
[IO.File]::WriteAllText((Join-Path $DataRoot 'version.json'), "{`r`n    `"version`": `"$packageVersion`"`r`n}", (New-Object System.Text.UTF8Encoding($false)))
$null = $actions.Add('DataRoot version.json обновлён (пользовательские файлы не тронуты)')

# ---------------- migration report ----------------
$report = [ordered]@{
    schema            = 1
    from              = $(if ($liveVersion) { $liveVersion } else { 'none' })
    to                = $packageVersion
    at                = (Get-Date).ToUniversalTime().ToString('o')
    layout            = @{ installRoot = $InstallRoot; dataRoot = $DataRoot; current = $currentFile }
    dataRootUntouched = $true
    actions           = @($actions)
}
[IO.File]::WriteAllText((Join-Path $DataRoot 'migration-report.json'), ($report | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
Write-Ok "миграция записана: $DataRoot\migration-report.json"

# ---------------- start ----------------
if (-not $NoStart) {
    $watcherExe = Join-Path $versionDir 'MGHelper.Watcher.exe'
    $hostExe = Join-Path $versionDir 'MG-Helper-Host.exe'
    $engine = if (Test-Path -LiteralPath $watcherExe) { $watcherExe } else { $hostExe }
    if (-not (Test-Path -LiteralPath $engine)) { Write-Warn2 "нет исполняемого файла watcher'а в $versionDir - установка не запущена"; exit 1 }
    try {
        $action = New-ScheduledTaskAction -Execute $engine -Argument ''
        $trigger1 = New-ScheduledTaskTrigger -AtLogOn
        $trigger2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger1, $trigger2) -Settings $settings -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Write-Ok "watcher запущен: $engine (задача $taskName)"
    } catch {
        Write-Warn2 "не удалось зарегистрировать задачу: $($_.Exception.Message)"
    }
}

Write-Ok "MG Helper $packageVersion установлен"
Write-Host "    InstallRoot: $InstallRoot"
Write-Host "    DataRoot:    $DataRoot"
Write-Host "    Откат:       .\install-3.0.ps1 -Rollback"
exit 0