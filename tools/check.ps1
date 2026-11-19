# MG Helper smoke harness - by Bayra & Kavel1n
# Run before every commit:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fail = $false
function Bad($m)  { Write-Host "[FAIL] $m" -ForegroundColor Red;  $script:fail = $true }
function Good($m) { Write-Host "[ok] $m"   -ForegroundColor Green }

$ps1 = Get-ChildItem $repo -Filter '*.ps1' -File -Recurse | Where-Object { $_.Name -ne 'rebuild-bats.ps1' }

# 1. syntax + duplicate functions
foreach ($f in $ps1) {
    $errs = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count) { Bad "$($f.Name): $($errs[0].Message)"; continue }
    $names = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name }
    $dups = $names | Group-Object | Where-Object { $_.Count -gt 1 }
    foreach ($d in $dups) { Bad "$($f.Name): function $($d.Name) defined $($d.Count) times" }
}
if (-not $fail) { Good 'all ps1 syntax OK, no duplicate functions' }

# 2. isolated sandbox for common.ps1
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("mg_check_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
# the sandbox must not leak even if a test throws ($ErrorActionPreference = 'Stop')
trap { Write-Host "[FAIL] harness crashed: $_" -ForegroundColor Red; Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue; exit 1 }
. (Join-Path $repo 'common.ps1')
$script:HelperDir  = $sandbox
$script:ConfigFile = Join-Path $sandbox 'config.json'

# 3. required functions present
foreach ($fn in 'Get-MgConfig','Save-MgConfig','Resolve-MgPaths','Find-MatchingProcess','Write-Atomic',
                'Test-GoldenValid','Get-ValidGolden','Apply-Golden','Get-MajesticBackupDir',
                'Ensure-BinsRestored','Restore-VanillaBackup','Get-PkgVersion') {
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { Bad "missing function $fn" }
}

# 4. Write-Atomic: replace existing target (catches N1) + create new target
$dst = Join-Path $sandbox 'settings.xml'
[IO.File]::WriteAllText($dst, 'OLD-CONTENT')
$bytes = [Text.Encoding]::UTF8.GetBytes('<Settings>new</Settings>')
if ((Write-Atomic -Path $dst -Bytes $bytes) -and ([IO.File]::ReadAllText($dst) -match 'new')) {
    Good 'Write-Atomic: replaces existing file'
} else { Bad 'Write-Atomic: does NOT replace existing file (bug N1)' }
$dst2 = Join-Path $sandbox 'new.xml'
if ((Write-Atomic -Path $dst2 -Bytes $bytes) -and (Test-Path $dst2)) {
    Good 'Write-Atomic: creates new file'
} else { Bad 'Write-Atomic: does not create new file' }

# 5. Test-GoldenValid
$g = Join-Path $sandbox 'golden.xml'
[IO.File]::WriteAllText($g, ('<Settings>' + ('x' * 150) + '</Settings>'))
if (Test-GoldenValid $g) { Good 'Test-GoldenValid: accepts valid' } else { Bad 'Test-GoldenValid: false negative' }
[IO.File]::WriteAllText($g, '<Settings>$1</Settings>')
if (-not (Test-GoldenValid $g)) { Good 'Test-GoldenValid: rejects corrupt' } else { Bad 'Test-GoldenValid: accepts corrupt' }

# 6. Save-MgConfig roundtrip - TWICE, so the [IO.File]::Replace path is exercised too
$cfg = Get-MgConfig
$cfg.settingsXml = 'C:\test\settings.xml'
Save-MgConfig $cfg
$cfg.settingsXml = 'C:\test\settings2.xml'
Save-MgConfig $cfg
$cfg2 = Get-MgConfig
if ($cfg2.settingsXml -eq 'C:\test\settings2.xml') { Good 'config roundtrip (create + replace)' } else { Bad 'config roundtrip / atomic replace' }

# 7. function arity check on positional calls (catches N2: Save-State $state $stateFile)
$funcParams = @{}
$allFiles = @($ps1)   # recursive discovery already includes this harness
foreach ($f in $allFiles) {
    $errs = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    foreach ($fd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        # paren syntax lands in $fd.Parameters, param() block lands in Body.ParamBlock - take the max
        $n1 = @($fd.Parameters).Count
        $n2 = 0
        if ($fd.Body.ParamBlock) { $n2 = @($fd.Body.ParamBlock.Parameters).Count }
        $funcParams[$fd.Name.ToLower()] = [Math]::Max($n1, $n2)
    }
}
foreach ($f in $ps1) {
    $errs = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if (-not $name -or -not $funcParams.ContainsKey($name.ToLower())) { continue }
        $elems = @($cmd.CommandElements | Select-Object -Skip 1)
        $hasNamed = $elems | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }
        if ($hasNamed) { continue }
        $pos = @($elems | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] }).Count
        if ($pos -gt $funcParams[$name.ToLower()]) {
            Bad "$($f.Name): call to $name with $pos args, function takes $($funcParams[$name.ToLower()])"
        }
    }
}

# 8. version.json present and in sync with common.ps1 (catches N3)
$vf = Join-Path $repo 'version.json'
if (-not (Test-Path $vf)) { Bad 'version.json missing from repo root' }
else {
    $v = (Get-Content $vf -Raw | ConvertFrom-Json).version
    $hardcoded = [regex]::Match((Get-Content (Join-Path $repo 'common.ps1') -Raw), '\$script:Version\s*=\s*''([^'']+)''').Groups[1].Value
    if ($v -ne $hardcoded) { Bad "version.json ($v) != common.ps1 ($hardcoded)" } else { Good "version.json = $v (in sync)" }
}

# 9. every ps1 has UTF-8 BOM (PS 5.1 + Cyrillic)
foreach ($f in $ps1) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
        Bad "$($f.Name): no UTF-8 BOM"
    }
}
if (-not $fail) { Good 'all ps1 have UTF-8 BOM' }

# 10. every script the menu / repair invoke must be deployed by the installer
$instTxt = Get-Content (Join-Path $repo 'install-gta-watcher.ps1') -Raw
$body = [regex]::Match($instTxt, '\$deploy\s*=\s*@\(([^)]*)\)').Groups[1].Value
$deployed = @([regex]::Matches($body, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
if ($deployed.Count -lt 5) { Bad 'cannot parse $deploy list in install-gta-watcher.ps1' }
foreach ($caller in 'MG-Helper.ps1', 'repair.ps1') {
    $txt = Get-Content (Join-Path $repo $caller) -Raw
    foreach ($m in [regex]::Matches($txt, "'([A-Za-z0-9\-]+\.ps1)'")) {
        $need = $m.Groups[1].Value
        if (($need -ne 'common.ps1') -and ($deployed -notcontains $need)) {
            Bad "$caller invokes $need, but the installer never deploys it"
        }
    }
}

# 11. session helpers: tri-state compare, guard window, adopt decision
$a = Join-Path $sandbox 'a.xml'; $b = Join-Path $sandbox 'b.xml'
[IO.File]::WriteAllText($a, "<Settings>`r`n  <X value=`"1`" />`r`n</Settings>")
[IO.File]::WriteAllText($b, '<Settings><X value="1" /></Settings>')
if ((Test-SameSettings $a $b) -eq $true) { Good 'Test-SameSettings: whitespace-insensitive equal' } else { Bad 'Test-SameSettings: whitespace treated as drift' }
[IO.File]::WriteAllText($b, '<Settings><X value="2" /></Settings>')
if ((Test-SameSettings $a $b) -eq $false) { Good 'Test-SameSettings: detects a real change' } else { Bad 'Test-SameSettings: missed a real change' }
if ($null -eq (Test-SameSettings $a (Join-Path $sandbox 'nope.xml'))) { Good 'Test-SameSettings: unreadable -> $null, not drift' } else { Bad 'Test-SameSettings: unreadable must return $null' }
$now = Get-Date
if (Test-GuardActive $now 120 $true $true) { Good 'guard: active inside the launch window' } else { Bad 'guard: inactive inside the window' }
if (-not (Test-GuardActive $now.AddSeconds(-600) 120 $true $true)) { Good 'guard: OFF after the window (user changes survive)' } else { Bad 'guard: still active after the window' }
if (-not (Test-GuardActive $now 120 $false $true)) { Good 'guard: config kill-switch works' } else { Bad 'guard: kill-switch ignored' }
if (-not (Test-GuardActive $null 120 $true $true)) { Good 'guard: no session -> inactive' } else { Bad 'guard: active without a session' }
if (Test-AdoptCandidate $true $true $false) { Good 'adopt: user change after our apply is adopted' } else { Bad 'adopt: user change rejected' }
if (-not (Test-AdoptCandidate $true $true $true)) { Good 'adopt: unchanged file is not adopted' } else { Bad 'adopt: unchanged file adopted' }
if (-not (Test-AdoptCandidate $true $true $null)) { Good 'adopt: unreadable file is not adopted' } else { Bad 'adopt: unreadable file adopted' }
if (-not (Test-AdoptCandidate $false $true $false)) { Good 'adopt: no write after our apply -> not adopted' } else { Bad 'adopt: adopted without a foreign write' }
if (-not (Test-AdoptCandidate $true $false $false)) { Good 'adopt: onExit=restore respected' } else { Bad 'adopt: onExit ignored' }

# 12. regression guards on the watcher source
$wtxt = Get-Content (Join-Path $repo 'gta-settings-watcher.ps1') -Raw
if ($wtxt -match '-not\s+\(Test-SameSettings') { Bad 'watcher: tri-state result used with -not (unreadable becomes drift)' }
if ($wtxt -match 'sessionReapplied\s*=\s*\$true') { Bad 'watcher: the adopt-blocking flag is back' }
if ($wtxt -notmatch '\}\s*finally\s*\{') { Bad 'watcher: $wasRunning must be updated in a finally block' }

# 13. hidden host: source deployed, installer compiles it and starts via the task,
#     watcher restarts defer during game sessions
$hostCs = Join-Path $repo 'MG-Helper-Host.cs'
if (-not (Test-Path $hostCs)) { Bad 'MG-Helper-Host.cs missing from repo' }
else {
    $hTxt = Get-Content $hostCs -Raw
    foreach ($needle in 'CreateNoWindow', 'TryOpenExisting', 'WaitForExit') {
        if ($hTxt -notmatch $needle) { Bad "MG-Helper-Host.cs: missing '$needle'" }
    }
    $instTxt2 = Get-Content (Join-Path $repo 'install-gta-watcher.ps1') -Raw
    if ($instTxt2 -notmatch 'MG-Helper-Host\.cs') { Bad 'installer: host source is not in the deploy list' }
    if ($instTxt2 -notmatch 'Add-Type.*OutputAssembly') { Bad 'installer: does not compile the hidden host' }
    if ($instTxt2 -notmatch 'Start-ScheduledTask') { Bad 'installer: must start the watcher via Start-ScheduledTask (no console flash)' }
}
$wtxt2 = Get-Content (Join-Path $repo 'gta-settings-watcher.ps1') -Raw
if ($wtxt2 -notmatch 'restartPending') { Bad 'watcher: self-restart is not deferred during game sessions' }
if ($wtxt2 -match 'Start-Process\s+\$psExe') { Bad 'watcher: direct powershell spawn remains (use the hidden host)' }

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host ''; Write-Host 'ERRORS FOUND - do not commit.' -ForegroundColor Red; exit 1 }
Write-Host ''; Write-Host 'ALL GREEN - safe to commit.' -ForegroundColor Green
exit 0
