# MG Helper smoke harness - by Bayra & Kavel1n
# Run before every commit:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fail = $false
function Bad($m)  { Write-Host "[FAIL] $m" -ForegroundColor Red;  $script:fail = $true }
function Good($m) { Write-Host "[ok] $m"   -ForegroundColor Green }

$ps1 = Get-ChildItem $repo -Filter '*.ps1' -File | Where-Object { $_.Name -ne 'rebuild-bats.ps1' }

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

# 6. Save-MgConfig roundtrip
$cfg = Get-MgConfig
$cfg.settingsXml = 'C:\test\settings.xml'
Save-MgConfig $cfg
$cfg2 = Get-MgConfig
if ($cfg2.settingsXml -eq 'C:\test\settings.xml') { Good 'config roundtrip' } else { Bad 'config roundtrip' }

# 7. function arity check on positional calls (catches N2: Save-State $state $stateFile)
$funcParams = @{}
$allFiles = @($ps1) + @(Get-Item $MyInvocation.MyCommand.Path)
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
    $hardcoded = [regex]::Match((Get-Content (Join-Path $repo 'common.ps1') -Raw), "\`$script:Version\s*=\s*'([^']+)'").Groups[1].Value
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

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host ''; Write-Host 'ERRORS FOUND - do not commit.' -ForegroundColor Red; exit 1 }
Write-Host ''; Write-Host 'ALL GREEN - safe to commit.' -ForegroundColor Green
exit 0
