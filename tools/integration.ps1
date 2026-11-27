# integration.ps1 - прогоняет НАСТОЯЩИЙ цикл watcher'а в песочнице (3.0, этап 1).
#
# Ничего живого не трогает: MG_HELPER_DIR направляет состояние в %TEMP%, а mutex и
# событие остановки в тестовом режиме живут в отдельном пространстве имён, поэтому
# тест работает рядом с боевым watcher'ом.
#
#   .\tools\integration.ps1            # подробный вывод, exit 1 при расхождении
#   .\tools\integration.ps1 -Quiet     # только итог
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$watcher = Join-Path $repo 'gta-settings-watcher.ps1'
if (-not (Test-Path -LiteralPath $watcher)) { throw "watcher not found: $watcher" }

$fails = New-Object System.Collections.Generic.List[string]
function Check([bool]$ok, [string]$what) {
    if ($ok) { if (-not $Quiet) { Write-Host "  PASS  $what" -ForegroundColor Green } }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $null = $script:fails.Add($what) }
}
function Wait-Until([scriptblock]$Cond, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

$sandbox = Join-Path $env:TEMP ('mg_int_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
foreach ($d in @($sandbox, (Join-Path $sandbox 'mg'), (Join-Path $sandbox 'cache'), (Join-Path $sandbox 'majestic\backup'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
$settings = Join-Path $sandbox 'settings.xml'
$xml = '<?xml version="1.0"?><Settings><graphics><TextureQuality value="2" /><MSAA value="0" /></graphics><pad>' + ('x' * 200) + '</pad></Settings>'
[IO.File]::WriteAllText($settings, $xml, [Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $sandbox 'settings.golden.xml'), $xml, [Text.UTF8Encoding]::new($true))
$majesticJson = Join-Path $sandbox 'majestic.json'
[IO.File]::WriteAllText($majesticJson, ('{"cachePath":"' + (Join-Path $sandbox 'cache').Replace('\', '\\') + '"}'), [Text.UTF8Encoding]::new($false))
$config = [ordered]@{
    version = 1; cfgVersion = 3
    settingsXml = $settings
    miamiGraphicsDir = (Join-Path $sandbox 'mg')
    majesticJson = $majesticJson
    lastFullDiscovery = ''
    gameProcesses = @('MGTESTGAME')
    launcherProcesses = @('MajesticTestLauncher')
    mgProcesses = @('MiamiTest')
    autoCleanDlccache = $false; autoUpdate = $false
    onExit = 'restore'; allowAdopt = $false; sessionGuard = $true; guardWindowSec = 0
    docsRoot = ''
}
[IO.File]::WriteAllText((Join-Path $sandbox 'config.json'), ($config | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldDir = $env:MG_HELPER_DIR
$env:MG_HELPER_DIR = $sandbox
$proc = $null
$fakeGame = $null
try {
    $proc = Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$watcher`"" -PassThru -WindowStyle Hidden
    $ready = Wait-Until { ((Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw -ErrorAction SilentlyContinue) -match '"status":"running"') } 90
    Check $ready 'watcher.start: health file appears in the sandbox'
    if (-not $ready) { throw 'watcher did not start' }
    # защита от утечки: watcher не должен уйти на живые пути пользователя
    $sandboxCfg = Get-Content (Join-Path $sandbox 'config.json') -Raw | ConvertFrom-Json
    Check ($sandboxCfg.settingsXml -like "$sandbox*") "isolation: watcher still writes inside the sandbox (settingsXml=$($sandboxCfg.settingsXml))"
    if ($sandboxCfg.settingsXml -notlike "$sandbox*") { throw 'sandbox escaped: refusing to continue' }
    $health = Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw | ConvertFrom-Json
    Check ($health.status -eq 'running') "health.status = running (got '$($health.status)')"
    Check ($health.phase -eq 'Idle') "health.phase = Idle before any session (got '$($health.phase)')"
    $healthAge = ((Get-Date).ToUniversalTime() - [datetime]::Parse($health.lastHeartbeatUtc).ToUniversalTime()).TotalSeconds
    Check ($healthAge -lt 15) "heartbeat is fresh ($([int]$healthAge) s)"
    $events = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue)
    Check ([bool]($events | Where-Object { $_ -match '"event":"watcher.start"' })) 'events: watcher.start emitted'
    Check ([bool]($events | Where-Object { $_ -match '"event":"watcher.ready"' })) 'events: watcher.ready emitted'

    $logText = if (Test-Path (Join-Path $sandbox 'watcher.log')) { (Get-Content (Join-Path $sandbox 'watcher.log') -Tail 6) -join ' | ' } else { '<no log>' }
    if (-not $Quiet -and $script:fails.Count -gt 0) { Write-Host ("    watcher.log: " + $logText) -ForegroundColor DarkGray }
    # --- сессия с фейковым процессом игры (пинг, переименованный в GTA5.exe) ---
    $fakeExe = Join-Path $sandbox 'MGTESTGAME.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $fakeExe -Force
    $fakeGame = Start-Process -FilePath $fakeExe -ArgumentList '-n', '120', '127.0.0.1' -PassThru -WindowStyle Hidden
    $inGame = Wait-Until { ((Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw -ErrorAction SilentlyContinue) -match '"phase":"InGame"') } 90
    Check $inGame 'session: a game process puts the watcher into InGame'
    $events = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue)
    Check ([bool]($events | Where-Object { $_ -match '"event":"session.start"' })) 'events: session.start emitted'
    Check ([bool]($events | Where-Object { $_ -match '"event":"golden.applied"' })) 'events: golden.applied (launch) emitted'
    Check (Test-Path -LiteralPath (Join-Path $sandbox 'settings.before_apply.bak')) 'session: pre-apply backup created'

    Stop-Process -Id $fakeGame.Id -Force -ErrorAction SilentlyContinue
    $fakeGame = $null
    $idle = Wait-Until { ((Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw -ErrorAction SilentlyContinue) -match '"phase":"Idle"') } 40
    Check $idle 'session: exit returns the watcher to Idle'
    $events = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue)
    Check ([bool]($events | Where-Object { $_ -match '"event":"session.end"' })) 'events: session.end emitted'
    Check (([IO.File]::ReadAllText($settings)) -eq $xml) 'settings.xml is byte-identical after the session (golden untouched)'

    # --- кооперативная остановка через файловый флаг (канал меню [2]/[11]) ---
    [IO.File]::WriteAllText((Join-Path $sandbox 'stop.request'), "requested=$(Get-Date -Format 'o')", [Text.UTF8Encoding]::new($false))
    $exited = Wait-Until { $proc.HasExited } 30
    Check $exited 'stop: watcher exits after stop.request'
    $events = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue)
    Check ([bool]($events | Where-Object { $_ -match '"event":"watcher.stop"' })) 'events: watcher.stop emitted'
    $h2 = Get-Content (Join-Path $sandbox 'watcher.health.json') -Raw | ConvertFrom-Json
    Check ($h2.status -eq 'stopping') "health.status = stopping after a clean exit (got '$($h2.status)')"
    Check (-not (Test-Path -LiteralPath (Join-Path $sandbox 'watcher.ready'))) 'watcher.ready removed on exit'

    # --- уровень событий: последовательность из tools\parity\expected-events.json ---
    $specPath = Join-Path $repo 'tools\parity\expected-events.json'
    if (Test-Path -LiteralPath $specPath) {
        $spec = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json
        $evs = @(Get-Content (Join-Path $sandbox 'events.jsonl') -ErrorAction SilentlyContinue |
                 ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
        $idx = -1; $seqOk = $true; $why = ''
        foreach ($want in @($spec.sequence)) {
            $found = -1
            for ($i = $idx + 1; $i -lt $evs.Count; $i++) { if ($evs[$i].event -eq $want.event) { $found = $i; break } }
            if ($found -lt 0) { $seqOk = $false; $why = "missing '$($want.event)' after position $idx"; break }
            $data = [string]$evs[$found].data
            if ($want.dataMode -eq 'prefix') {
                if (-not $data.StartsWith([string]$want.data)) { $seqOk = $false; $why = "'$($want.event)' data '$data' does not start with '$($want.data)'"; break }
            } elseif ($null -ne $want.data -and $data -ne [string]$want.data) {
                $seqOk = $false; $why = "'$($want.event)' data '$data' != '$($want.data)'"; break
            }
            $idx = $found
        }
        Check $seqOk ("events: the sequence matches expected-events.json" + $(if ($seqOk) { '' } else { " ($why)" }))
        $forbidden = @($spec.forbid)
        $bad = @($evs | Where-Object { $forbidden -contains $_.event })
        Check ($bad.Count -eq 0) ("events: none of the forbidden events in a clean run" + $(if ($bad.Count) { " (got: " + (($bad | ForEach-Object { $_.event }) -join ', ') + ")" } else { '' }))
    }
}
catch {
    Check $false ("integration crashed: " + $_.Exception.Message)
}
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if ($fakeGame -and -not $fakeGame.HasExited) { Stop-Process -Id $fakeGame.Id -Force -ErrorAction SilentlyContinue }
    $env:MG_HELPER_DIR = $oldDir
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails.Count -gt 0) {
    Write-Host ("INTEGRATION FAILED: {0} check(s)" -f $fails.Count) -ForegroundColor Red
    exit 1
}
if (-not $Quiet) { Write-Host 'INTEGRATION OK - real watcher loop behaves as expected in a sandbox' -ForegroundColor Green }
else { Write-Host 'INTEGRATION OK' }
exit 0