# parity.ps1 - parity runner for the 3.0 strangler step (docs/ROADMAP-3.0.md §4).
#
# Runs the scenarios from tools\parity\expected.json against ONE implementation and
# compares the outcome with the expectation. Two implementations exist:
#   ps   - MgHelper.Core.ps1 through common.ps1 (the reference)
#   core - CoreDecisions.cs compiled to MgCore.exe (the future watcher core)
# Both must pass the same expected.json; that is the gate for stage 5.
#
#   . .\tools\parity.ps1                                   # dot-source: Invoke-ParityScenarios
#   .\tools\parity.ps1                                     # run all scenarios (ps), exit 1 on divergence
#   .\tools\parity.ps1 -Implementation core                # run the C# core instead
#   .\tools\parity.ps1 -Both -Quiet                        # gate used by tools\check.ps1
[CmdletBinding()]
param(
    [ValidateSet('ps', 'core')][string]$Implementation = 'ps',
    [switch]$Both,
    [switch]$Quiet,
    [string]$ExpectedPath
)

$ErrorActionPreference = 'Stop'
$script:parityRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:parityRoot 'common.ps1')

function New-ParitySandbox {
    $dir = Join-Path $env:TEMP ('mg_parity_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function New-ParityXml([string]$Tag) {
    # >100 bytes: Test-GoldenValid rejects suspiciously short files
    return "<?xml version=`"1.0`"?><Settings><graphics><TextureQuality value=`"2`" /><MSAA value=`"0`" /></graphics><pad>" + $Tag + ('x' * 120) + "</pad></Settings>"
}

function New-ParityFixture {
    # создаёт файлы сценария и возвращает всё, что нужно обеим реализациям
    param([object]$Scenario)
    $kind = [string]$Scenario.kind
    $in = $Scenario.inputs
    $sbx = New-ParitySandbox
    $paths = @{}
    $req = @{}
    switch ($kind) {
        'guard' {
            $start = $null
            if ($null -ne $in.sessionStartOffsetSec) { $start = (Get-Date).ToUniversalTime().AddSeconds([int]$in.sessionStartOffsetSec).ToString('o') }
            $req = @{ sessionStart = $start; windowSec = [int]$in.windowSec; guardEnabled = [bool]$in.guardEnabled; gameRunning = [bool]$in.gameRunning }
        }
        'adopt' {
            $same = $in.same
            if ($null -ne $same) { $same = [bool]$same }
            $req = @{ changedAfterUs = [bool]$in.changedAfterUs; allowAdopt = [bool]$in.allowAdopt; same = $same; appliedThisSession = [bool]$in.appliedThisSession }
        }
        'golden-source' {
            $paths = New-ParityGoldenFiles -Dir $sbx -GoldenValid ([bool]$in.goldenValid) -GoldenBakValid ([bool]$in.goldenBakValid) -LiveValid ([bool]$in.liveValid)
            $req = @{ allowLiveFallback = [bool]$in.allowLiveFallback }
        }
        'apply' {
            $paths = New-ParityGoldenFiles -Dir $sbx -GoldenValid ([bool]$in.goldenValid) -GoldenBakValid ([bool]$in.goldenBakValid) -LiveValid $true
            [IO.File]::WriteAllText($paths.live, (New-ParityXml ([string]$in.liveTag)), [Text.UTF8Encoding]::new($true))
            $req = @{}
        }
        'compare' {
            $a = Join-Path $sbx 'a.xml'; $b = Join-Path $sbx 'b.xml'
            [IO.File]::WriteAllText($a, [string]$in.a, [Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText($b, [string]$in.b, [Text.UTF8Encoding]::new($true))
            $paths = @{ a = $a; b = $b }
            $req = @{}
        }
        'policy' {
            $allow = $null
            if ($null -ne $in.allowAdopt) { $allow = [bool]$in.allowAdopt }
            $req = @{ cfgVersion = [int]$in.cfgVersion; guardWindowSec = [int]$in.guardWindowSec; allowAdopt = $allow }
        }
        default { throw "unknown scenario kind '$kind'" }
    }
    return @{ sandbox = $sbx; kind = $kind; request = $req; paths = $paths }
}

function New-ParityGoldenFiles {
    param([string]$Dir, [bool]$GoldenValid, [bool]$GoldenBakValid, [bool]$LiveValid)
    $golden = Join-Path $Dir 'settings.golden.xml'
    $goldenBak = Join-Path $Dir 'settings.golden.xml.bak'
    $beforeApply = Join-Path $Dir 'settings.before_apply.bak'
    $live = Join-Path $Dir 'settings.xml'
    if ($GoldenValid) { [IO.File]::WriteAllText($golden, (New-ParityXml 'GOLDEN'), [Text.UTF8Encoding]::new($true)) }
    else { [IO.File]::WriteAllText($golden, '<Settings>torn', [Text.UTF8Encoding]::new($true)) }
    if ($GoldenBakValid) { [IO.File]::WriteAllText($goldenBak, (New-ParityXml 'GOLDEN-BAK'), [Text.UTF8Encoding]::new($true)) }
    if ($LiveValid) {
        [IO.File]::WriteAllText($beforeApply, (New-ParityXml 'MAJESTIC-OVERWRITE'), [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText($live, (New-ParityXml 'USER-LIVE'), [Text.UTF8Encoding]::new($true))
    }
    return @{ golden = $golden; goldenBak = $goldenBak; beforeApply = $beforeApply; live = $live }
}

function Get-ParityTag([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    $t = [IO.File]::ReadAllText($Path)
    foreach ($tag in 'GOLDEN-BAK', 'MAJESTIC-OVERWRITE', 'USER-LIVE', 'OLD-LIVE', 'GOLDEN') { if ($t.Contains($tag)) { return $tag } }
    return 'UNKNOWN'
}

function Invoke-PsActual {
    # считает результат на PS-реализации (MgHelper.Core.ps1 через common.ps1)
    param([hashtable]$Fixture, [object]$Scenario)
    $kind = $Fixture.kind
    $in = $Scenario.inputs
    $p = $Fixture.paths
    $sbx = $Fixture.sandbox
    $oldHelper = $script:HelperDir
    try {
        $script:HelperDir = $sbx
        switch ($kind) {
            'guard' {
                $start = $null
                if ($null -ne $in.sessionStartOffsetSec) { $start = (Get-Date).ToUniversalTime().AddSeconds([int]$in.sessionStartOffsetSec) }
                return @{ active = [bool](Test-GuardActive $start ([int]$in.windowSec) ([bool]$in.guardEnabled) ([bool]$in.gameRunning)) }
            }
            'adopt' {
                $same = $in.same
                if ($null -ne $same) { $same = [bool]$same }
                return @{ adopt = [bool](Test-AdoptCandidate ([bool]$in.changedAfterUs) ([bool]$in.allowAdopt) $same ([bool]$in.appliedThisSession)) }
            }
            'golden-source' {
                $src = if ($in.allowLiveFallback) { Get-ValidGolden -CfgSettingsXml $p.live -AllowLiveFallback } else { Get-ValidGolden -CfgSettingsXml $p.live }
                $sourceName = $null
                if ($src) {
                    if ($src.path -eq $p.golden) { $sourceName = 'golden' }
                    elseif ($src.path -eq $p.goldenBak) { $sourceName = 'golden.bak' }
                    elseif ($src.path -eq $p.beforeApply) { $sourceName = 'before_apply' }
                    elseif ($src.path -eq $p.live) { $sourceName = 'live' }
                    else { $sourceName = 'other' }
                }
                return @{ source = $sourceName; healed = $(if ($src) { [bool]$src.healed } else { $null }) }
            }
            'apply' {
                $applied = [bool](Apply-Golden -Cfg @{ settingsXml = $p.live })
                return @{ applied = $applied; liveTag = (Get-ParityTag $p.live) }
            }
            'compare' {
                return @{ same = (Test-SameSettings $p.a $p.b) }
            }
            'policy' {
                $cfg = @{ cfgVersion = [int]$in.cfgVersion; guardWindowSec = [int]$in.guardWindowSec }
                if ($null -ne $in.allowAdopt) { $cfg.allowAdopt = [bool]$in.allowAdopt }
                $null = Update-MgConfigPolicy $cfg
                return @{ cfgVersion = [int]$cfg.cfgVersion; guardWindowSec = [int]$cfg.guardWindowSec; allowAdopt = $cfg.allowAdopt }
            }
        }
    } finally { $script:HelperDir = $oldHelper }
}

function Get-MgCoreExe {
    # компилирует CoreDecisions.cs в %TEMP%\MgCore.exe, если он старше исходника
    param([switch]$Force)
    $src = Join-Path $script:parityRoot 'CoreDecisions.cs'
    if (-not (Test-Path -LiteralPath $src)) { throw "CoreDecisions.cs not found: $src" }
    $exe = Join-Path $env:TEMP 'MgCore.exe'
    $needBuild = $Force -or (-not (Test-Path -LiteralPath $exe)) -or ((Get-Item $exe).LastWriteTimeUtc -lt (Get-Item $src).LastWriteTimeUtc)
    if ($needBuild) {
        if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue }
        $code = [IO.File]::ReadAllText($src)
        Add-Type -TypeDefinition $code -ReferencedAssemblies @('System.Web.Extensions', 'System.Xml', 'System.Core') -OutputAssembly $exe -OutputType ConsoleApplication -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $exe)) { throw 'core compilation produced no exe' }
    }
    return $exe
}

function Invoke-CoreActual {
    # считает результат на C#-ядре через MgCore.exe --decide
    param([hashtable]$Fixture, [object]$Scenario, [string]$CoreExe)
    $request = @{ kind = $Fixture.kind; inputs = $Fixture.request; paths = $Fixture.paths }
    $reqFile = Join-Path $Fixture.sandbox 'request.json'
    $resFile = Join-Path $Fixture.sandbox 'response.json'
    [IO.File]::WriteAllText($reqFile, ($request | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $out = & $CoreExe --decide $reqFile $resFile 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("MgCore.exe failed: " + (($out | Select-Object -Last 3) -join ' | ')) }
    $response = Get-Content -LiteralPath $resFile -Raw | ConvertFrom-Json
    $actual = @{}
    foreach ($p in $response.actual.PSObject.Properties) { $actual[$p.Name] = $p.Value }
    return $actual
}

function Invoke-ParityScenario {
    # выполняет один сценарий выбранной реализацией и сравнивает с ожиданием
    param([object]$Scenario, [string]$Implementation, [string]$CoreExe)
    $result = @{ id = [string]$Scenario.id; ok = $false; expected = $Scenario.expect; actual = $null; error = $null }
    $fixture = $null
    try {
        $fixture = New-ParityFixture -Scenario $Scenario
        if ($Implementation -eq 'core') { $actual = Invoke-CoreActual -Fixture $fixture -Scenario $Scenario -CoreExe $CoreExe }
        else { $actual = Invoke-PsActual -Fixture $fixture -Scenario $Scenario }
        $result.actual = $actual
        $ok = $true
        $mismatch = @()
        foreach ($prop in @($Scenario.expect.PSObject.Properties)) {
            $exp = $prop.Value
            $act = $actual[$prop.Name]
            $equal = if ($null -eq $exp -and $null -eq $act) { $true }
                     elseif ($null -eq $exp -or $null -eq $act) { $false }
                     elseif ($exp -is [bool] -or $act -is [bool]) { ([bool]$exp) -eq ([bool]$act) }
                     else { "$exp" -eq "$act" }
            if (-not $equal) { $ok = $false; $mismatch += "$($prop.Name): expected '$exp', got '$act'" }
        }
        $result.ok = $ok
        if (-not $ok) { $result.error = ($mismatch -join '; ') }
    } catch {
        $result.ok = $false
        $result.error = $_.Exception.Message
    } finally {
        if ($fixture -and $fixture.sandbox) { Remove-Item $fixture.sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $result
}

function Invoke-ParityScenarios {
    param([string]$Implementation = 'ps', [switch]$Quiet, [string]$ExpectedPath)
    if (-not $ExpectedPath) { $ExpectedPath = Join-Path $PSScriptRoot 'parity\expected.json' }
    if (-not (Test-Path -LiteralPath $ExpectedPath)) { throw "expected.json not found: $ExpectedPath" }
    $spec = Get-Content -LiteralPath $ExpectedPath -Raw | ConvertFrom-Json
    if (-not $spec.scenarios -or @($spec.scenarios).Count -eq 0) { throw 'expected.json has no scenarios' }
    $coreExe = $null
    if ($Implementation -eq 'core') { $coreExe = Get-MgCoreExe }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($sc in @($spec.scenarios)) {
        $r = Invoke-ParityScenario -Scenario $sc -Implementation $Implementation -CoreExe $coreExe
        $null = $results.Add($r)
        if (-not $Quiet) {
            if ($r.ok) { Write-Host ("  PASS  [{0}] {1}" -f $Implementation, $r.id) -ForegroundColor Green }
            else { Write-Host ("  FAIL  [{0}] {1}`n        {2}" -f $Implementation, $r.id, $r.error) -ForegroundColor Red }
        }
    }
    return $results
}

function Invoke-ParityBoth {
    # прогон обеих реализаций; расхождение любой = провал gate
    param([switch]$Quiet, [string]$ExpectedPath)
    $ps = @(Invoke-ParityScenarios -Implementation ps -Quiet:$Quiet -ExpectedPath $ExpectedPath)
    $core = @(Invoke-ParityScenarios -Implementation core -Quiet:$Quiet -ExpectedPath $ExpectedPath)
    $failedPs = @($ps | Where-Object { -not $_.ok })
    $failedCore = @($core | Where-Object { -not $_.ok })
    # сверка реализаций между собой: одинаковые фактические значения на каждом сценарии
    $cross = @()
    for ($i = 0; $i -lt [Math]::Min($ps.Count, $core.Count); $i++) {
        if ($ps[$i].ok -and $core[$i].ok) {
            foreach ($key in $ps[$i].actual.Keys) {
                if ("$($ps[$i].actual[$key])" -ne "$($core[$i].actual[$key])") { $cross += "$($ps[$i].id).$key" }
            }
        }
    }
    return @{
        ps = $ps; core = $core
        failedPs = $failedPs.Count; failedCore = $failedCore.Count
        total = $ps.Count; crossMismatch = $cross
    }
}

# CLI mode: only when executed, not when dot-sourced by tools\check.ps1
if ($MyInvocation.InvocationName -ne '.') {
    if ($Both) {
        $r = Invoke-ParityBoth -Quiet:$Quiet -ExpectedPath $ExpectedPath
        if ($r.failedPs -gt 0 -or $r.failedCore -gt 0 -or @($r.crossMismatch).Count -gt 0) {
            Write-Host ("PARITY FAILED: ps {0}/{1}, core {2}/{1}, cross-mismatch {3}" -f $r.failedPs, $r.total, $r.failedCore, @($r.crossMismatch).Count) -ForegroundColor Red
            @($r.ps + $r.core) | Where-Object { -not $_.ok } | ForEach-Object { Write-Host ("  [{0}] {1}: {2}" -f 'x', $_.id, $_.error) -ForegroundColor Red }
            exit 1
        }
        Write-Host ("PARITY OK - ps and core both match expected.json ({0}/{0})" -f $r.total) -ForegroundColor Green
        exit 0
    }
    $results = @(Invoke-ParityScenarios -Implementation $Implementation -Quiet:$Quiet -ExpectedPath $ExpectedPath)
    $failed = @($results | Where-Object { -not $_.ok })
    if ($failed.Count -gt 0) {
        Write-Host ("PARITY FAILED: {0} of {1} scenarios diverged ({2})" -f $failed.Count, $results.Count, $Implementation) -ForegroundColor Red
        $failed | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.id, $_.error) -ForegroundColor Red }
        exit 1
    }
    Write-Host ("PARITY OK - {0}/{0} scenarios match expected.json ({1})" -f $results.Count, $Implementation) -ForegroundColor Green
    exit 0
}