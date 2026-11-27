# build-core.ps1 - builds the 3.0 C# artifacts into a staging folder (PS 5.1, net48)
#
#   MgCore.exe            decisions (CoreDecisions.cs) + --decide CLI, used by parity
#   MGHelper.Watcher.exe  the C# watcher (MGHelper.Watcher.cs + HelperPipe.cs, links MgCore)
#
# Both are built with Add-Type/CodeDom (C# 5), the same path the installer uses for
# the hidden host and the tray. Rebuilds only when a source file is newer.
#
#   .\tools\build-core.ps1                 # build into %TEMP%\mg_build
#   .\tools\build-core.ps1 -OutputDir <p>  # build elsewhere (installer staging)
[CmdletBinding()]
param([string]$OutputDir, [switch]$Force)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $env:TEMP 'mg_build' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function StripUsings([string]$text) {
    $lines = [regex]::Split($text, "\r?\n")
    $out = New-Object System.Collections.Generic.List[string]
    $inHeader = $true
    foreach ($line in $lines) {
        if ($inHeader -and $line -match '^\s*using\s+[\w.]+\s*;\s*$') { continue }
        if ($inHeader -and ($line -match '^\s*//' -or $line -match '^\s*$')) { $out.Add($line); continue }
        $inHeader = $false
        $out.Add($line)
    }
    return ($out -join "`r`n")
}

function Build([string]$Name, [string]$Source, [string[]]$ExtraSources, [string[]]$References) {
    $exe = Join-Path $OutputDir $Name
    $sources = @($Source) + @($ExtraSources)
    $newest = ($sources | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } | Sort-Object -Descending | Select-Object -First 1)
    if (-not $Force -and (Test-Path -LiteralPath $exe) -and ((Get-Item -LiteralPath $exe).LastWriteTimeUtc -ge $newest)) { return $exe }
    if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
    # несколько .cs склеиваются в один файл: у первых using-блок остаётся, у остальных срезается,
    # иначе компилятор ругается на директивы в середине файла
    $parts = @()
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $text = [IO.File]::ReadAllText($sources[$i])
        if ($i -gt 0) { $text = StripUsings $text }
        $parts += $text
    }
    $code = $parts -join "`r`n"
    $refs = @('System.Core')
    if ($References) { $refs += $References }
    Add-Type -TypeDefinition $code -ReferencedAssemblies $refs -OutputAssembly $exe -OutputType ConsoleApplication -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $exe)) { throw "build produced no exe: $exe" }
    return $exe
}

$coreSrc = Join-Path $repo 'CoreDecisions.cs'
$watcherSrc = Join-Path $repo 'MGHelper.Watcher.cs'
$pipeSrc = Join-Path $repo 'HelperPipe.cs'
foreach ($f in @($coreSrc, $watcherSrc, $pipeSrc)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing source: $f" } }

$coreExe = Build 'MgCore.exe' $coreSrc @() @('System.Web.Extensions', 'System.Xml')
# отдельная библиотека для ссылки из watcher'а: ссылаться на exe через CodeDom нельзя
$coreDll = Join-Path $OutputDir 'MgCore.dll'
$needDll = $Force -or (-not (Test-Path -LiteralPath $coreDll)) -or ((Get-Item -LiteralPath $coreDll).LastWriteTimeUtc -lt (Get-Item -LiteralPath $coreSrc).LastWriteTimeUtc)
if ($needDll) {
    if (Test-Path -LiteralPath $coreDll) { Remove-Item -LiteralPath $coreDll -Force }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($coreSrc)) -ReferencedAssemblies @('System.Core', 'System.Web.Extensions', 'System.Xml') -OutputAssembly $coreDll -OutputType Library -ErrorAction Stop
}
$watcherExe = Build 'MGHelper.Watcher.exe' $watcherSrc @($pipeSrc) @($coreDll, 'System.Web.Extensions', 'System.Xml')
Write-Output $coreDll

Write-Output $coreExe
Write-Output $watcherExe