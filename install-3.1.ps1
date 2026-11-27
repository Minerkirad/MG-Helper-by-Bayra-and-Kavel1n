# install-3.1.ps1 - финализация установки 3.1: переключить current.json на каталог,
# из которого запущены, обновить скрипты поддержки в DataRoot, настроить автозапуск.
#
# Вызывается установщиком Inno Setup после копирования файлов:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "<app>\install-3.1.ps1" -Version <ver>
# вручную (портативный ZIP):
#   .\install-3.1.ps1 -Version 3.1.0-beta.1
#
# Ничего не удаляет: пользовательские файлы DataRoot (config, эталон, снапшоты, .bin)
# остаются на месте, старые версии в App\Versions остаются для отката.
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$NoStart,
    [switch]$Quiet,
    [string]$DataRoot,
    [string]$VersionDir
)

$ErrorActionPreference = 'Stop'
function Write-InstallerLine([string]$text, [string]$color = 'Gray') { if (-not $Quiet) { Write-Host $text -ForegroundColor $color } }

if (-not $VersionDir) { $VersionDir = $PSScriptRoot }
$VersionDir = [IO.Path]::GetFullPath($VersionDir)
$installRoot = Split-Path (Split-Path $VersionDir -Parent) -Parent
$versionsDir = Split-Path $VersionDir -Parent
if (-not $DataRoot) {
    $DataRoot = if ($env:MG_HELPER_DIR) { $env:MG_HELPER_DIR } else { Split-Path $installRoot -Parent }
}
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
if (-not $Version) {
    try { $Version = [string](Get-Content -LiteralPath (Join-Path $VersionDir 'version.json') -Raw | ConvertFrom-Json).version } catch { $Version = Split-Path $VersionDir -Leaf }
}
Write-Host "[*] MG Helper $Version" -ForegroundColor Cyan
Write-InstallerLine "    version dir: $VersionDir"
Write-InstallerLine "    data root:   $DataRoot"
if (-not (Test-Path -LiteralPath (Join-Path $VersionDir 'MGHelper.exe'))) { throw "в $VersionDir нет MGHelper.exe - установка неполная" }

$actions = New-Object System.Collections.Generic.List[string]
$taskName = 'MG_Helper_Watcher'

# --- 1. остановить текущий watcher (канал, затем файл-флаг) ---
function Stop-Watcher {
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $(if ($env:MG_HELPER_DIR) { 'MG_Helper_test' } else { 'MG_Helper' }), [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(1200)
        $w = New-Object System.IO.StreamWriter($pipe); $w.AutoFlush = $true
        $w.WriteLine('{"cmd":"stop"}')
        $null = (New-Object System.IO.StreamReader($pipe)).ReadLine()
        $actions.Add('watcher: остановлен через канал')
        Write-InstallerLine '[i] старый watcher остановлен через канал'
    } catch {
        try { [IO.File]::WriteAllText((Join-Path $DataRoot 'stop.request'), (Get-Date).ToUniversalTime().ToString('o'), [Text.UTF8Encoding]::new($false)); $actions.Add('watcher: остановлен файлом-флагом') } catch { }
    } finally { $pipe.Dispose() }
    if (-not $env:MG_HELPER_DIR) {
        try { & schtasks /End /TN $taskName 2>&1 | Out-Null } catch { }
    }
    Start-Sleep -Milliseconds 1200
}
Stop-Watcher

# --- 2. переключить указатель версии ---
$currentFile = Join-Path $installRoot 'current.json'
$payload = [ordered]@{
    version = $Version
    path    = "Versions\$Version"
    updated = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 3
$tmp = "$currentFile.tmp"
[IO.File]::WriteAllText($tmp, $payload, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tmp -Destination $currentFile -Force
$actions.Add("current.json -> $Version")
Write-Host "[+] current.json -> $Version" -ForegroundColor Green

# --- 3. скрипты поддержки в DataRoot (меню, диагностика, обновление) ---
$tooling = @(
    'common.ps1', 'MgHelper.Core.ps1', 'gta-settings-watcher.ps1', 'MG-Helper.ps1', 'MG-Helper.bat',
    'diagnose.ps1', 'uninstall.ps1', 'repair.ps1', 'reset-settings.ps1', 'import-settings.ps1',
    'clean-majestic-cache.ps1', 'max-fps.ps1', 'cut-shadows.ps1', 'restore-mg-snapshot.ps1',
    'restore-golden-history.ps1', 'save-custom-profile.ps1', 'apply-custom-profile.ps1',
    'update-helper.ps1', 'install-gta-watcher.ps1', 'install-3.0.ps1', 'install-3.1.ps1'
)
foreach ($f in $tooling) {
    $src = Join-Path $VersionDir $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $DataRoot $f) -Force }
}
[IO.File]::WriteAllText((Join-Path $DataRoot 'version.json'), "{`r`n    `"version`": `"$Version`"`r`n}", (New-Object System.Text.UTF8Encoding($false)))
$actions.Add('DataRoot: скрипты поддержки и маркер версии обновлены (данные не тронуты)')
Write-Host '[+] скрипты поддержки обновлены, данные не тронуты' -ForegroundColor Green

# --- 4. автозапуск: задача для watcher'а + ярлык приложения в автозагрузке ---
if (-not $NoStart) {
    $watcherExe = Join-Path $VersionDir 'MGHelper.Watcher.exe'
    $appExe = Join-Path $VersionDir 'MGHelper.exe'
    if (Test-Path -LiteralPath $watcherExe) {
        & schtasks /Create /F /SC MINUTE /MO 10 /TN $taskName /TR "`"$watcherExe`"" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $actions.Add("задача $taskName -> $watcherExe") }
        else { Write-Host '[!] задачу зарегистрировать не удалось' -ForegroundColor Yellow }
        try { & schtasks /Run /TN $taskName 2>&1 | Out-Null } catch { }
    }
    $startup = [Environment]::GetFolderPath('Startup')
    if ($startup -and (Test-Path -LiteralPath $startup) -and (Test-Path -LiteralPath $appExe)) {
        $lnkPath = Join-Path $startup 'MG Helper.lnk'
        try {
            $ws = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($lnkPath)
            $lnk.TargetPath = $appExe
            $lnk.WorkingDirectory = $VersionDir
            $lnk.IconLocation = (Join-Path $VersionDir 'ui\assets\mghelper.ico')
            $lnk.Description = 'MG Helper - защита настроек GTA V'
            $lnk.Save()
            $actions.Add("автозапуск приложения: $lnkPath")
        } catch { Write-Host "[!] ярлык автозапуска не создан: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    # запустить приложение (оно же поднимет трей и покажет статус)
    if (Test-Path -LiteralPath $appExe) { Start-Process -FilePath $appExe -WindowStyle Normal }
}

# --- 5. отчёт об установке ---
$report = [ordered]@{
    schema            = 1
    from              = $(if ($env:MG_HELPER_DIR) { 'sandbox' } else { 'previous' })
    to                = $Version
    at                = (Get-Date).ToUniversalTime().ToString('o')
    layout            = @{ installRoot = $installRoot; dataRoot = $DataRoot; versionDir = $VersionDir }
    dataRootUntouched = $true
    actions           = @($actions)
}
[IO.File]::WriteAllText((Join-Path $DataRoot 'migration-report.json'), ($report | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
Write-Host "[+] установка $Version завершена" -ForegroundColor Green
exit 0