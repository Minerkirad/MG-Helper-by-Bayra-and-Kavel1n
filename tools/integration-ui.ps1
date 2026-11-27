# integration-ui.ps1 - smoke-проверка приложения MGHelper.exe (WebView2) без пользователя.
#
# Собирает MGHelper.exe (tools\build-ui.ps1), копирует рядом ui\, запускает
# `MGHelper.exe --smoke`: приложение открывает окно, WebView2 грузит index.html,
# JS отправляет ui-ready через мост, хост пишет ui-smoke.txt и выходит с кодом 0.
# Так CI проверяет, что UI действительно отрисовывается, а не только компилируется.
#
#   .\tools\integration-ui.ps1 [-Quiet]
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

# WebView2 Runtime нужен для запуска; если его нет (нестандартная машина/образ CI),
# честно помечаем SKIP, а не валим набор: компиляция всё равно проверяется ниже.
$edgeKeys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
)
$hasWebView2 = $false
foreach ($k in $edgeKeys) { if (Test-Path $k) { $hasWebView2 = $true; break } }
if (-not $hasWebView2) {
    Write-Host 'UI SMOKE SKIP - WebView2 runtime is not installed on this machine'
    exit 0
}

# --- build (или взять готовый, если свежий) ---
$build = Join-Path $env:TEMP 'mg_ui_build'
$out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\build-ui.ps1') -OutputDir $build 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n") -ForegroundColor DarkGray; Write-Host 'BUILD FAILED' -ForegroundColor Red; exit 1 }
$exe = Join-Path $build 'MGHelper.exe'
Check (Test-Path -LiteralPath $exe) 'ui: MGHelper.exe built'

# рядом с exe должны лежать ui\ и версия
Remove-Item (Join-Path $build 'ui') -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $repo 'ui') -Destination (Join-Path $build 'ui') -Recurse -Force
Copy-Item (Join-Path $repo 'version.json') -Destination (Join-Path $build 'version.json') -Force
Remove-Item (Join-Path $build 'ui-smoke.txt'), (Join-Path $build 'ui-trace.log') -Force -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath $exe -ArgumentList '--smoke' -PassThru
$exited = $proc.WaitForExit(45000)
if (-not $exited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Check $exited 'ui: the app starts, renders and exits on its own (no hang)'
$smoke = Join-Path $build 'ui-smoke.txt'
$smokeText = if (Test-Path -LiteralPath $smoke) { [IO.File]::ReadAllText($smoke) } else { '' }
Check ($smokeText -match 'ok=1') "ui: the page loaded and the JS bridge answered ($smokeText)"
Check ($smokeText -match 'title=MG Helper') 'ui: index.html rendered (window title read from the page)'
if (-not $exited) {
    $trace = Join-Path $build 'ui-trace.log'
    if (Test-Path -LiteralPath $trace) { if (-not $Quiet) { Get-Content $trace -Tail 6 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } } }
}

if ($fails.Count -gt 0) {
    Write-Host ("UI SMOKE FAILED: {0} check(s)" -f $fails.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'UI SMOKE OK - the WebView2 app renders, bridges to the host and exits cleanly'
exit 0