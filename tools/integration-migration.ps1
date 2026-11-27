# integration-migration.ps1 - миграция живой 2.6.1 -> 3.0 на КОПИИ (3.0, этап 6).
#
# Берёт резервную копию живой установки 2.6.1 (backups\2.6.1\live-install-*.zip),
# разворачивает её в песочницу как DataRoot, запускает install-3.0.ps1 в тестовом
# режиме (MG_INSTALL_ROOT) и проверяет: раскладку Versions/current.json, манифест с
# SHA256, сохранность пользовательских файлов, идемпотентность, откат указателем и
# запрет отката версии. Живая установка не участвует.
#
#   .\tools\integration-migration.ps1 [-Quiet]
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fails = New-Object System.Collections.Generic.List[string]
function Check([bool]$ok, [string]$what) {
    if ($ok) { if (-not $Quiet) { Write-Host "  PASS  $what" -ForegroundColor Green } }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $null = $script:fails.Add($what) }
}
function HashOf([string]$Path) { if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } return $null }

# Фикстура: реальный бэкап 2.6.1, если он есть рядом (машина разработчика), иначе -
# синтетическая «живая папка 2.6.1», собранная из этого же пакета. CI обязан быть
# самодостаточным: репозиторий не хранит гигабайтные бэкапы.
$backup = Get-ChildItem (Join-Path $repo '..\backups\2.6.1') -Filter 'live-install-*.zip' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$sandbox = Join-Path $env:TEMP ('mg_migr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$data = Join-Path $sandbox 'MG_Helper'
$app = Join-Path $data 'App'
New-Item -ItemType Directory -Force -Path $data | Out-Null
if ($backup) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($backup.FullName, $data)
    if (-not $Quiet) { Write-Host "  fixture: real 2.6.1 backup ($($backup.Name))" -ForegroundColor DarkGray }
} else {
    # синтетическая живая папка 2.6.1: скрипты из пакета + версия 2.6.1 + пользовательские файлы
    foreach ($name in 'common.ps1','gta-settings-watcher.ps1','MG-Helper.ps1','diagnose.ps1') {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $data $name) -Force -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText((Join-Path $data 'version.json'), "{`r`n    `"version`": `"2.6.1`"`r`n}", (New-Object System.Text.UTF8Encoding($false)))
    $fixtureXml = '<?xml version="1.0"?><Settings><graphics><TextureQuality value="2" /></graphics><pad>' + ('x' * 200) + '</pad></Settings>'
    [IO.File]::WriteAllText((Join-Path $data 'settings.golden.xml'), $fixtureXml, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $sandbox 'settings.xml'), $fixtureXml, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $data 'golden_key.json'), '{"variant":"GTA V","gpu":"Fixture GPU"}', [Text.UTF8Encoding]::new($false))
    $fixtureCfg = [ordered]@{
        version = 1; cfgVersion = 3
        settingsXml = (Join-Path $sandbox 'settings.xml')
        miamiGraphicsDir = ''; majesticJson = ''; lastFullDiscovery = ''
        gameProcesses = @('GTA5','GTA5_Enhanced'); launcherProcesses = @('Majestic'); mgProcesses = @('Miami')
        autoCleanDlccache = $false; autoUpdate = $false
        onExit = 'restore'; allowAdopt = $false; sessionGuard = $true; guardWindowSec = 0; docsRoot = ''
    }
    [IO.File]::WriteAllText((Join-Path $data 'config.json'), ($fixtureCfg | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    if (-not $Quiet) { Write-Host '  fixture: synthetic 2.6.1 live folder (no local backup)' -ForegroundColor DarkGray }
}

$oldData = $env:MG_HELPER_DIR
$oldApp = $env:MG_INSTALL_ROOT
$env:MG_HELPER_DIR = $data
$env:MG_INSTALL_ROOT = $app
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installer = Join-Path $repo 'install-3.0.ps1'
$packageVersion = ([IO.File]::ReadAllText((Join-Path $repo 'version.json')) | ConvertFrom-Json).version

try {
    $configHash = HashOf (Join-Path $data 'config.json')
    $goldenHash = HashOf (Join-Path $data 'settings.golden.xml')
    $keyHash = HashOf (Join-Path $data 'golden_key.json')
    $liveVersionBefore = ([IO.File]::ReadAllText((Join-Path $data 'version.json')) | ConvertFrom-Json).version

    # --- 1. миграция ---
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $installer -NoStart -SkipCompile 2>&1
    $code = $LASTEXITCODE
    if (-not $Quiet -and $code -ne 0) { $out | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    Check ($code -eq 0) "migration: install-3.0.ps1 exits 0 (was $liveVersionBefore -> $packageVersion)"
    $versionDir = Join-Path $app ("Versions\$packageVersion")
    Check (Test-Path -LiteralPath (Join-Path $versionDir 'common.ps1')) 'migration: version dir contains the deployed scripts'
    Check (Test-Path -LiteralPath (Join-Path $versionDir 'manifest.json')) 'migration: version dir has manifest.json'
    Check (-not (Test-Path -LiteralPath (Join-Path $app ("Versions\$packageVersion.incomplete")))) 'migration: no .incomplete staging left behind'
    $current = $null
    try { $current = ([IO.File]::ReadAllText((Join-Path $app 'current.json')) | ConvertFrom-Json) } catch { }
    Check ($current -and $current.version -eq $packageVersion) "migration: current.json points at $packageVersion"
    Check ($current -and $current.path -eq "Versions\$packageVersion") 'migration: current.json records the relative version path'

    # манифест должен сходиться
    $manifest = $null
    try { $manifest = [IO.File]::ReadAllText((Join-Path $versionDir 'manifest.json')) | ConvertFrom-Json } catch { }
    $bad = @()
    if ($manifest) { foreach ($prop in $manifest.files.PSObject.Properties) { if ((HashOf (Join-Path $versionDir $prop.Name)) -ne $prop.Value) { $bad += $prop.Name } } }
    Check ($manifest -and $bad.Count -eq 0) 'migration: every file matches its SHA256 in the manifest'

    # --- 2. пользовательские данные не тронуты ---
    Check ((HashOf (Join-Path $data 'config.json')) -eq $configHash) 'migration: config.json untouched'
    Check ((HashOf (Join-Path $data 'settings.golden.xml')) -eq $goldenHash) 'migration: golden untouched'
    Check ((HashOf (Join-Path $data 'golden_key.json')) -eq $keyHash) 'migration: golden_key.json untouched'
    $report = $null
    try { $report = [IO.File]::ReadAllText((Join-Path $data 'migration-report.json')) | ConvertFrom-Json } catch { }
    Check ($report -and $report.to -eq $packageVersion -and $report.dataRootUntouched -eq $true) 'migration: migration-report.json written and honest'
    Check (([IO.File]::ReadAllText((Join-Path $data 'version.json')) | ConvertFrom-Json).version -eq $packageVersion) 'migration: DataRoot version marker updated'

    # --- 3. идемпотентность ---
    $out2 = & $ps -NoProfile -ExecutionPolicy Bypass -File $installer -NoStart -SkipCompile 2>&1
    Check ($LASTEXITCODE -eq 0) 'migration: a second run is idempotent (exit 0)'
    Check ((HashOf (Join-Path $data 'config.json')) -eq $configHash) 'migration: second run keeps user data untouched'

    # --- 4. откат указателем ---
    $prevDir = Join-Path $app "Versions\$packageVersion.previous"
    New-Item -ItemType Directory -Force -Path $prevDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $prevDir 'marker.txt'), 'previous', [Text.UTF8Encoding]::new($false))
    $rb = & $ps -NoProfile -ExecutionPolicy Bypass -File $installer -Rollback 2>&1
    $curAfter = $null
    try { $curAfter = ([IO.File]::ReadAllText((Join-Path $app 'current.json')) | ConvertFrom-Json).version } catch { }
    Check ($LASTEXITCODE -eq 0 -and $curAfter -eq "$packageVersion.previous") "migration: -Rollback switches current.json to the previous version (got '$curAfter')"
    foreach ($d in @($prevDir)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    $null = & $ps -NoProfile -ExecutionPolicy Bypass -File $installer -NoStart -SkipCompile 2>&1

    # --- 5. запрет отката на старую версию ---
    $versionFile = Join-Path $data 'version.json'
    $savedVersion = [IO.File]::ReadAllText($versionFile)
    [IO.File]::WriteAllText($versionFile, "{`"version`": `"9.9.9`"}", (New-Object System.Text.UTF8Encoding($false)))
    $blocked = & $ps -NoProfile -ExecutionPolicy Bypass -File $installer -NoStart -SkipCompile 2>&1
    Check ($LASTEXITCODE -ne 0) 'migration: an older package cannot overwrite a newer install (guard)'
    [IO.File]::WriteAllText($versionFile, $savedVersion, (New-Object System.Text.UTF8Encoding($false)))
}
catch {
    Check $false ("migration crashed: " + $_.Exception.Message)
}
finally {
    $env:MG_HELPER_DIR = $oldData
    $env:MG_INSTALL_ROOT = $oldApp
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails.Count -gt 0) {
    Write-Host ("MIGRATION FAILED: {0} check(s)" -f $fails.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'MIGRATION OK - 2.6.1 backup migrates to the 3.0 layout, data untouched, rollback works'
exit 0