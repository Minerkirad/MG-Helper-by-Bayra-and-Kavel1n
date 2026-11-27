# integration-portability.ps1 - проверка, что функционал работает не только на машине
# разработчика: путь с пробелами и кириллицей, отсутствие WebView2 (упрощённый режим),
# отчёт об окружении, установщик без прав администратора.
#
#   .\tools\integration-portability.ps1 [-Quiet]
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fails = New-Object System.Collections.Generic.List[string]
function Check([bool]$ok, [string]$what) {
    if ($ok) { if (-not $Quiet) { Write-Host "  PASS  $what" -ForegroundColor Green } }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $null = $script:fails.Add($what) }
}

# "враждебное" окружение: пробелы + кириллица в пути (частая причина поломок на чужих машинах)
$root = Join-Path $env:TEMP ('MG Helper портатив ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$data = Join-Path $root 'MG_Helper'
$verDir = Join-Path $data 'App\Versions\3.1.0-beta.1'
$build = Join-Path $env:TEMP 'mg_build'
New-Item -ItemType Directory -Force -Path $verDir | Out-Null

$exe = Join-Path $build 'MGHelper.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    $null = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\build-ui.ps1') -Force 2>&1
}
Check (Test-Path -LiteralPath $exe) 'portability: the app is built'

# --- 1. установка в путь с пробелами и кириллицей, без прав администратора ---
$stage = Join-Path $repo 'release\stage'
if (Test-Path -LiteralPath $stage) {
    Copy-Item (Join-Path $stage '*') -Destination $verDir -Recurse -Force
} else {
    Copy-Item $exe -Destination $verDir -Force
    foreach ($f in 'common.ps1', 'install-3.1.ps1', 'version.json') {
        $src = Join-Path $repo $f
        if (Test-Path -LiteralPath $src) { Copy-Item $src -Destination $verDir -Force }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $verDir 'ui') | Out-Null
    Copy-Item (Join-Path $repo 'ui\*') -Destination (Join-Path $verDir 'ui') -Recurse -Force -ErrorAction SilentlyContinue
}
Copy-Item (Join-Path $repo 'install-3.1.ps1') -Destination $verDir -Force
Copy-Item (Join-Path $repo 'ui') -Destination (Join-Path $verDir 'ui') -Recurse -Force -ErrorAction SilentlyContinue
# всегда кладём СВЕЖУЮ сборку: в release\stage может лежать предыдущая версия
foreach ($artifact in 'MGHelper.exe', 'MGHelper.Watcher.exe', 'MgCore.dll', 'MgCore.exe', 'WebView2Loader.dll', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll') {
    $src = Join-Path $build $artifact
    if (Test-Path -LiteralPath $src) { Copy-Item $src -Destination $verDir -Force }
}

$env:MG_HELPER_DIR = $data
try {
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $verDir 'install-3.1.ps1') -NoStart -Quiet 2>&1
    Check ($LASTEXITCODE -eq 0) 'portability: install-3.1 works from a path with spaces and Cyrillic'
    $current = $null
    try { $current = Get-Content (Join-Path $data 'App\current.json') -Raw | ConvertFrom-Json } catch { }
    Check ($current -and $current.version) 'portability: current.json written in a non-ASCII DataRoot'
    Check (Test-Path -LiteralPath (Join-Path $data 'common.ps1')) 'portability: support scripts copied into the DataRoot'

    # --- 2. приложение без WebView2 (упрощённый режим) ---
    $env:MG_UI_FORCE_FALLBACK = '1'
    $smoke = Join-Path $verDir 'ui-smoke.txt'
    Remove-Item $smoke -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath (Join-Path $verDir 'MGHelper.exe') -ArgumentList '--smoke' -PassThru
    $done = $proc.WaitForExit(45000)
    if (-not $done) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $smokeText = if (Test-Path -LiteralPath $smoke) { [IO.File]::ReadAllText($smoke) } else { '' }
    Check ($done -and $smokeText -match 'ok=1' -and $smokeText -match 'fallback=1') "portability: app starts and exits in fallback mode ($smokeText)"
    $env:MG_UI_FORCE_FALLBACK = $null

    # --- 3. отчёт об окружении ---
    $envFile = Join-Path $verDir 'ui-env.json'
    Remove-Item $envFile -Force -ErrorAction SilentlyContinue
    $proc2 = Start-Process -FilePath (Join-Path $verDir 'MGHelper.exe') -ArgumentList '--env' -PassThru
    $done2 = $proc2.WaitForExit(30000)
    if (-not $done2) { Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue }
    $envJson = $null
    try { $envJson = [IO.File]::ReadAllText($envFile) | ConvertFrom-Json } catch { }
    Check ($done2 -and $envJson) 'portability: --env writes ui-env.json (environment self-report)'
    if ($envJson) {
        $reportedRoot = [string]$envJson.dataRoot; $expectedRoot = [IO.Path]::GetFullPath($data); Check ($reportedRoot.TrimEnd('\') -eq $expectedRoot.TrimEnd('\')) ('portability: the report sees the redirected DataRoot [report=' + $reportedRoot + ' expected=' + $expectedRoot + ']')
        Check ($envJson.dataRootWritable -eq $true) 'portability: the report verifies the DataRoot is writable'
        Check ([bool]$envJson.pipe) 'portability: the report names the pipe used at runtime'
    }
}
catch {
    Check $false ("portability test crashed: " + $_.Exception.Message)
}
finally {
    $env:MG_HELPER_DIR = $null
    $env:MG_UI_FORCE_FALLBACK = $null
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails.Count -gt 0) {
    Write-Host ("PORTABILITY FAILED: {0} check(s)" -f $fails.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'PORTABILITY OK - non-ASCII paths, missing WebView2 and the env report all work'
exit 0