# integration-core.ps1 - end-to-end run of the C# watcher (MGHelper.Watcher.exe) in a sandbox.
# Mirrors tools\integration.ps1 (PS watcher) so both implementations are judged by the same
# invariants: launch -> apply, foreign overwrite -> rollback, exit -> untouched golden,
# pipe commands, clean stop. DataRoot is redirected with MG_HELPER_DIR.
#
#   .\tools\integration-core.ps1            # verbose
#   .\tools\integration-core.ps1 -Quiet     # summary only
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fails = New-Object System.Collections.Generic.List[string]
function Check([bool]$ok, [string]$what) {
    if ($ok) { if (-not $Quiet) { Write-Host "  PASS  $what" -ForegroundColor Green } }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $null = $script:fails.Add($what) }
}
function Wait-Until([scriptblock]$Cond, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 400 }
    return $false
}
function LogHas([string]$Dir, [string]$Pattern) {
    $f = Join-Path $Dir 'watcher.log'
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    return ([IO.File]::ReadAllText($f) -match $Pattern)
}

# --- build ---
$buildOut = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\build-core.ps1') 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host ($buildOut -join "`n") -ForegroundColor Red; throw 'build failed' }
$watcherExe = Join-Path $env:TEMP 'mg_build\MGHelper.Watcher.exe'
if (-not (Test-Path -LiteralPath $watcherExe)) { throw "watcher exe not built: $watcherExe" }
Copy-Item -LiteralPath (Join-Path $repo 'version.json') -Destination (Join-Path (Split-Path $watcherExe -Parent) 'version.json') -Force

# --- sandbox ---
$sandbox = Join-Path $env:TEMP ('mg_intcore_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
foreach ($d in @($sandbox, (Join-Path $sandbox 'mg'), (Join-Path $sandbox 'cache'), (Join-Path $sandbox 'majestic\backup'))) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$settings = Join-Path $sandbox 'settings.xml'
$xml = '<?xml version="1.0"?><Settings><graphics><TextureQuality value="2" /><MSAA value="0" /></graphics><pad>' + ('x' * 200) + '</pad></Settings>'
[IO.File]::WriteAllText($settings, $xml, [Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $sandbox 'settings.golden.xml'), $xml, [Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $sandbox 'majestic.json'), ('{"cachePath":"' + (Join-Path $sandbox 'cache').Replace('\', '\\') + '"}'), [Text.UTF8Encoding]::new($false))
$cfg = [ordered]@{
    version = 1; cfgVersion = 3; settingsXml = $settings
    miamiGraphicsDir = (Join-Path $sandbox 'mg'); majesticJson = (Join-Path $sandbox 'majestic.json')
    lastFullDiscovery = ''; gameProcesses = @('MGTESTGAME'); launcherProcesses = @('MajesticTestLauncher')
    mgProcesses = @('MiamiTest'); autoCleanDlccache = $false; autoUpdate = $false
    onExit = 'restore'; allowAdopt = $false; sessionGuard = $true; guardWindowSec = 0; docsRoot = ''
}
[IO.File]::WriteAllText((Join-Path $sandbox 'config.json'), ($cfg | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

$oldDir = $env:MG_HELPER_DIR
$env:MG_HELPER_DIR = $sandbox
. (Join-Path $repo 'common.ps1')   # клиент канала (Get-MgPipeName смотрит на MG_HELPER_DIR)
$proc = $null; $fakeGame = $null
try {
    $proc = Start-Process -FilePath $watcherExe -PassThru -WindowStyle Hidden
    $running = Wait-Until { ((Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw -ErrorAction SilentlyContinue) -match '"status":"running"') } 90
    Check $running 'core: watcher (C#) reaches status=running'
    if (-not $running) { throw 'C# watcher did not start' }
    $cfgNow = Get-Content (Join-Path $sandbox 'config.json') -Raw | ConvertFrom-Json
    Check ($cfgNow.settingsXml -like "$sandbox*") 'core: isolation - state stays inside the sandbox'
    Check (LogHas $sandbox 'watcher READY') 'core: READY written'
    $events = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue)
    Check ([bool]($events | Where-Object { $_ -match '"event":"watcher.start"' -or $_ -match '"event":"watcher.ready"' })) 'core: start events emitted'

    $fakeExe = Join-Path $sandbox 'MGTESTGAME.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $fakeExe -Force
    $fakeGame = Start-Process -FilePath $fakeExe -ArgumentList '-n', '200', '127.0.0.1' -PassThru -WindowStyle Hidden
    $inGame = Wait-Until { ((Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw -ErrorAction SilentlyContinue) -match '"phase":"InGame"') } 60
    Check $inGame 'core: a game process puts the C# watcher into InGame'
    Check (Test-Path -LiteralPath (Join-Path $sandbox 'settings.before_apply.bak')) 'core: pre-apply backup created'
    $events = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue)
    Check ([bool]($events | Where-Object { $_ -match '"event":"golden.applied"' })) 'core: golden.applied (launch) emitted'
    Check ([bool]($events | Where-Object { $_ -match '"event":"session.start"' })) 'core: session.start emitted'

    # foreign overwrite that really changes a value -> the guard must roll it back
    $foreign = $xml.Replace('<MSAA value="0" />', '<MSAA value="8" />')
    [IO.File]::WriteAllText($settings, $foreign, [Text.UTF8Encoding]::new($false))
    $rolled = Wait-Until { LogHas $sandbox 'session guard: foreign overwrite' } 60
    Check $rolled 'core: guard rolls back a foreign overwrite during the session'
    Check ([IO.File]::ReadAllText($settings) -eq $xml) 'core: settings.xml is back to the golden bytes'

    Stop-Process -Id $fakeGame.Id -Force -ErrorAction SilentlyContinue
    $fakeGame = $null
    $idle = Wait-Until { ((Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw -ErrorAction SilentlyContinue) -match '"phase":"Idle"') } 60
    Check $idle 'core: exit returns the C# watcher to Idle'
    Check ([IO.File]::ReadAllText($settings) -eq $xml) 'core: golden untouched after the session'
    $events = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue)
    Check ([bool]($events | Where-Object { $_ -match '"event":"session.end"' })) 'core: session.end emitted'

    # pipe commands (same surface as the PS watcher)
    $statusResp = Invoke-MgPipeCommand -Command 'status'
    Check ([bool]($statusResp -and $statusResp.ok)) 'core: pipe status answers ok'
    $null = Invoke-MgPipeCommand -Command 'reload-config'
    Check (Wait-Until { LogHas $sandbox 'config reloaded \(pipe request\)' } 20) 'core: pipe reload-config is executed'
    $null = Invoke-MgPipeCommand -Command 'apply-golden'
    Check (Wait-Until { LogHas $sandbox 'golden applied \(pipe request\)' } 20) 'core: pipe apply-golden is executed'

    $null = Invoke-MgPipeCommand -Command 'stop'
    $exited = Wait-Until { $proc.HasExited } 30
    Check $exited 'core: pipe stop terminates the C# watcher'
    $h = Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    Check ($h.status -eq 'stopping') 'core: health ends with status=stopping'
    Check (-not (Test-Path -LiteralPath (Join-Path $sandbox 'watcher.ready'))) 'core: watcher.ready removed on exit'
    $events = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue)
    Check ([bool]($events | Where-Object { $_ -match '"event":"watcher.stop"' })) 'core: watcher.stop emitted'
    $forbidden = @('"event":"error"', '"event":"apply.failed"', '"event":"golden.mismatch"', '"event":"session.unknown"')
    $bad = @($events | Where-Object { $e = $_; @($forbidden | Where-Object { $e -match $_ }).Count -gt 0 })
    Check ($bad.Count -eq 0) ("core: no forbidden events in a clean run" + $(if ($bad.Count) { " (got: " + ($bad -join ' | ') + ")" } else { '' }))
}
catch {
    Check $false ("core integration crashed: " + $_.Exception.Message)
}
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if ($fakeGame -and -not $fakeGame.HasExited) { Stop-Process -Id $fakeGame.Id -Force -ErrorAction SilentlyContinue }
    $env:MG_HELPER_DIR = $oldDir
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails.Count -gt 0) {
    Write-Host ("CORE INTEGRATION FAILED: {0} check(s)" -f $fails.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'CORE INTEGRATION OK - the C# watcher behaves like the PS one in a sandbox'
exit 0