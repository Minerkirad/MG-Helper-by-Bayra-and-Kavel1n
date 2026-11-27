# parity.ps1 - parity runner for the 3.0 strangler step (docs/ROADMAP-3.0.md §4).
#
# Runs the scenarios from tools\parity\expected.json against ONE implementation and
# compares the outcome with the expectation. Today the only implementation is the
# PS watcher (functions from common.ps1); the C# core will be plugged in with
# -Implementation core when it exists, and the same expected.json must pass.
#
#   . .\tools\parity.ps1                                   # dot-source: Invoke-ParityScenarios
#   .\tools\parity.ps1                                     # run all scenarios, exit 1 on divergence
#   .\tools\parity.ps1 -Quiet                              # summary only
#   .\tools\parity.ps1 -Implementation core                # future C# core (not implemented yet)
[CmdletBinding()]
param(
    [ValidateSet('ps', 'core')][string]$Implementation = 'ps',
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

function Get-ParityTag([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    $t = [IO.File]::ReadAllText($Path)
    foreach ($tag in 'GOLDEN-BAK', 'MAJESTIC-OVERWRITE', 'USER-LIVE', 'OLD-LIVE', 'GOLDEN') {
        if ($t.Contains($tag)) { return $tag }
    }
    return 'UNKNOWN'
}

function Invoke-ParityScenario {
    # Executes one scenario against the selected implementation.
    # Returns @{ id; ok; expected; actual; error }
    param([object]$Scenario, [string]$Implementation)
    $id = [string]$Scenario.id
    $kind = [string]$Scenario.kind
    $in = $Scenario.inputs
    $sbx = New-ParitySandbox
    $oldHelper = $script:HelperDir
    $result = @{ id = $id; ok = $false; expected = $Scenario.expect; actual = $null; error = $null }
    try {
        $script:HelperDir = $sbx
        switch ($kind) {
            'guard' {
                $start = $null
                if ($null -ne $in.sessionStartOffsetSec) { $start = (Get-Date).ToUniversalTime().AddSeconds([int]$in.sessionStartOffsetSec) }
                $result.actual = @{ active = [bool](Test-GuardActive $start ([int]$in.windowSec) ([bool]$in.guardEnabled) ([bool]$in.gameRunning)) }
            }
            'adopt' {
                $same = $in.same
                if ($null -ne $same) { $same = [bool]$same }
                $result.actual = @{ adopt = [bool](Test-AdoptCandidate ([bool]$in.changedAfterUs) ([bool]$in.allowAdopt) $same ([bool]$in.appliedThisSession)) }
            }
            'golden-source' {
                $golden = Join-Path $sbx 'settings.golden.xml'
                $goldenBak = Join-Path $sbx 'settings.golden.xml.bak'
                $beforeApply = Join-Path $sbx 'settings.before_apply.bak'
                $live = Join-Path $sbx 'settings.xml'
                if ($in.goldenValid) { [IO.File]::WriteAllText($golden, (New-ParityXml 'GOLDEN'), [Text.UTF8Encoding]::new($true)) }
                else { [IO.File]::WriteAllText($golden, '<Settings>torn', [Text.UTF8Encoding]::new($true)) }
                if ($in.goldenBakValid) { [IO.File]::WriteAllText($goldenBak, (New-ParityXml 'GOLDEN-BAK'), [Text.UTF8Encoding]::new($true)) }
                if ($in.liveValid) {
                    [IO.File]::WriteAllText($beforeApply, (New-ParityXml 'MAJESTIC-OVERWRITE'), [Text.UTF8Encoding]::new($true))
                    [IO.File]::WriteAllText($live, (New-ParityXml 'USER-LIVE'), [Text.UTF8Encoding]::new($true))
                }
                $src = $null
                if ($in.allowLiveFallback) { $src = Get-ValidGolden -CfgSettingsXml $live -AllowLiveFallback }
                else { $src = Get-ValidGolden -CfgSettingsXml $live }
                $sourceName = $null
                if ($src) {
                    if ($src.path -eq $golden) { $sourceName = 'golden' }
                    elseif ($src.path -eq $goldenBak) { $sourceName = 'golden.bak' }
                    elseif ($src.path -eq $beforeApply) { $sourceName = 'before_apply' }
                    elseif ($src.path -eq $live) { $sourceName = 'live' }
                    else { $sourceName = 'other' }
                }
                $result.actual = @{ source = $sourceName; healed = $(if ($src) { [bool]$src.healed } else { $null }) }
            }
            'apply' {
                $golden = Join-Path $sbx 'settings.golden.xml'
                $goldenBak = Join-Path $sbx 'settings.golden.xml.bak'
                $beforeApply = Join-Path $sbx 'settings.before_apply.bak'
                $live = Join-Path $sbx 'settings.xml'
                if ($in.goldenValid) { [IO.File]::WriteAllText($golden, (New-ParityXml 'GOLDEN'), [Text.UTF8Encoding]::new($true)) }
                else { [IO.File]::WriteAllText($golden, '<Settings>torn', [Text.UTF8Encoding]::new($true)) }
                if ($in.goldenBakValid) { [IO.File]::WriteAllText($goldenBak, (New-ParityXml 'GOLDEN-BAK'), [Text.UTF8Encoding]::new($true)) }
                [IO.File]::WriteAllText($beforeApply, (New-ParityXml 'MAJESTIC-OVERWRITE'), [Text.UTF8Encoding]::new($true))
                [IO.File]::WriteAllText($live, (New-ParityXml ([string]$in.liveTag)), [Text.UTF8Encoding]::new($true))
                $applied = [bool](Apply-Golden -Cfg @{ settingsXml = $live })
                $result.actual = @{ applied = $applied; liveTag = (Get-ParityTag $live) }
            }
            'compare' {
                $a = Join-Path $sbx 'a.xml'
                $b = Join-Path $sbx 'b.xml'
                [IO.File]::WriteAllText($a, [string]$in.a, [Text.UTF8Encoding]::new($true))
                [IO.File]::WriteAllText($b, [string]$in.b, [Text.UTF8Encoding]::new($true))
                $result.actual = @{ same = (Test-SameSettings $a $b) }
            }
            'policy' {
                $cfg = @{ cfgVersion = [int]$in.cfgVersion; guardWindowSec = [int]$in.guardWindowSec }
                if ($null -ne $in.allowAdopt) { $cfg.allowAdopt = [bool]$in.allowAdopt }
                $null = Update-MgConfigPolicy $cfg
                $result.actual = @{ cfgVersion = [int]$cfg.cfgVersion; guardWindowSec = [int]$cfg.guardWindowSec; allowAdopt = $cfg.allowAdopt }
            }
            default { throw "unknown scenario kind '$kind'" }
        }
        # compare every expected field
        $ok = $true
        $mismatch = @()
        foreach ($p in @($Scenario.expect.PSObject.Properties)) {
            $exp = $p.Value
            $act = $result.actual[$p.Name]
            $equal = if ($null -eq $exp -and $null -eq $act) { $true }
                     elseif ($null -eq $exp -or $null -eq $act) { $false }
                     elseif ($exp -is [bool] -or $act -is [bool]) { ([bool]$exp) -eq ([bool]$act) }
                     else { "$exp" -eq "$act" }
            if (-not $equal) { $ok = $false; $mismatch += "$($p.Name): expected '$exp', got '$act'" }
        }
        $result.ok = $ok
        if (-not $ok) { $result.error = ($mismatch -join '; ') }
    } catch {
        $result.ok = $false
        $result.error = $_.Exception.Message
    } finally {
        $script:HelperDir = $oldHelper
        Remove-Item $sbx -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Invoke-ParityScenarios {
    param([string]$Implementation = 'ps', [switch]$Quiet, [string]$ExpectedPath)
    if ($Implementation -ne 'ps') { throw "implementation '$Implementation' is not available yet (3.0 stage C); expected.json is the contract it must pass" }
    if (-not $ExpectedPath) { $ExpectedPath = Join-Path $PSScriptRoot 'parity\expected.json' }
    if (-not (Test-Path -LiteralPath $ExpectedPath)) { throw "expected.json not found: $ExpectedPath" }
    $spec = Get-Content -LiteralPath $ExpectedPath -Raw | ConvertFrom-Json
    if (-not $spec.scenarios -or @($spec.scenarios).Count -eq 0) { throw 'expected.json has no scenarios' }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($sc in @($spec.scenarios)) {
        $r = Invoke-ParityScenario -Scenario $sc -Implementation $Implementation
        $null = $results.Add($r)
        if (-not $Quiet) {
            if ($r.ok) { Write-Host ("  PASS  {0}  {1}" -f $r.id, $sc.desc) -ForegroundColor Green }
            else { Write-Host ("  FAIL  {0}  {1}`n        {2}" -f $r.id, $sc.desc, $r.error) -ForegroundColor Red }
        }
    }
    return $results
}

# CLI mode: only when executed, not when dot-sourced by tools\check.ps1
if ($MyInvocation.InvocationName -ne '.') {
    $results = Invoke-ParityScenarios -Implementation $Implementation -Quiet:$Quiet -ExpectedPath $ExpectedPath
    $failed = @($results | Where-Object { -not $_.ok })
    $total = @($results).Count
    if ($failed.Count -gt 0) {
        Write-Host ("PARITY FAILED: {0} of {1} scenarios diverged ({2})" -f $failed.Count, $total, $Implementation) -ForegroundColor Red
        $failed | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.id, $_.error) -ForegroundColor Red }
        exit 1
    }
    Write-Host ("PARITY OK - {0}/{0} scenarios match expected.json ({1})" -f $total, $Implementation) -ForegroundColor Green
    exit 0
}