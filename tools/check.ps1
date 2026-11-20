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
                'Ensure-BinsRestored','Restore-VanillaBackup','Get-PkgVersion',
                'Get-ExeNamesFromCommandLine','Get-CachedWalk','Archive-VanillaBins','Prune-BackupFiles',
                'Get-LatestBinArchive','Snapshot-MgFiles') {
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
$null = Save-MgConfig $cfg
$cfg.settingsXml = 'C:\test\settings2.xml'
$null = Save-MgConfig $cfg
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
if (Test-AdoptCandidate $true $true $false $true) { Good 'adopt: user change after our apply is adopted' } else { Bad 'adopt: user change rejected' }
if (-not (Test-AdoptCandidate $true $true $true $true)) { Good 'adopt: unchanged file is not adopted' } else { Bad 'adopt: unchanged file adopted' }
if (-not (Test-AdoptCandidate $true $true $null $true)) { Good 'adopt: unreadable file is not adopted' } else { Bad 'adopt: unreadable file adopted' }
if (-not (Test-AdoptCandidate $false $true $false $true)) { Good 'adopt: no write after our apply -> not adopted' } else { Bad 'adopt: adopted without a foreign write' }
if (-not (Test-AdoptCandidate $true $false $false $true)) { Good 'adopt: onExit=restore respected' } else { Bad 'adopt: onExit ignored' }
if (-not (Test-AdoptCandidate $true $true $false $false)) { Good 'adopt: never-applied session cannot adopt (poisoning regression)' } else { Bad 'adopt: foreign overwrite adopted without our apply' }

# 11k. Snapshot-MgFiles round-trip: '__' inside the MG path must resolve exactly,
#      and a legacy-name leftover with the same prefix must be swept
$mgWeird = Join-Path $sandbox 'MG__weird'
New-Item -ItemType Directory -Force -Path (Join-Path $mgWeird 'sub__dir') | Out-Null
[IO.File]::WriteAllText((Join-Path $mgWeird 'config__gpu.json'), '{"gpu":1}')
[IO.File]::WriteAllText((Join-Path $mgWeird 'sub__dir\opts.json'), '{"o":1}')
$legacyName = (($mgWeird -replace '[:\\/]', '_')) + '__config__gpu.json'   # ambiguous legacy snapshot name
New-Item -ItemType Directory -Force -Path (Join-Path $sandbox 'mg_snapshot') | Out-Null
[IO.File]::WriteAllText((Join-Path $sandbox "mg_snapshot\$legacyName"), 'LEGACY-LEFTOVER')
$logged = @()
Snapshot-MgFiles -Cfg @{ miamiGraphicsDir = $mgWeird } -Logger { param($m) $script:logged += $m } -NoStandardScan
# ROADMAP 2.4: the newest GENERATION dir with its own manifest
$genDir = @(Get-ChildItem (Join-Path $sandbox 'mg_snapshot') -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
    Sort-Object Name -Descending)[0]
if ($genDir) {
    $mani = Get-Content -LiteralPath (Join-Path $genDir.FullName 'manifest.json') -Raw | ConvertFrom-Json
    $okRT = @($mani.PSObject.Properties).Count -ge 2
    foreach ($p in $mani.PSObject.Properties) {
        if (-not (Test-Path -LiteralPath (Join-Path $mgWeird $p.Value))) { $okRT = $false }
    }
    if ($okRT -and (Test-Path -LiteralPath (Join-Path $sandbox "mg_snapshot\$legacyName"))) {
        Good 'snapshot: round-trip paths resolve exactly, generation layout (legacy fallback untouched)'
    } else { Bad 'snapshot: round-trip broken in generation layout' }
} else { Bad 'snapshot: manifest.json not written' }

# 11b. exe-token matching: document paths must not look like the game
$n1 = Get-ExeNamesFromCommandLine 'notepad "C:\Games\GTA5\settings.xml"'
if ($n1 -notcontains 'GTA5') { Good 'exe-match: document path is not the game' } else { Bad 'exe-match: document path looks like GTA5' }
$n2 = Get-ExeNamesFromCommandLine '"C:\Games\Renamed.exe" -game "C:\GTA V\GTA5.exe"'
if ($n2 -contains 'GTA5') { Good 'exe-match: renamed-binary argument still detected' } else { Bad 'exe-match: renamed-binary case lost' }
$n3 = Get-ExeNamesFromCommandLine '"C:\Program Files\Rockstar Games\GTA V\GTA5.exe" -nobattleye'
if ($n3 -contains 'GTA5') { Good 'exe-match: quoted exe with spaces' } else { Bad 'exe-match: quoted exe missed' }

# 11c. Restore-VanillaBackup: a stale archive must never downgrade fresh bins
$mjDir = Join-Path $sandbox 'majestic'
New-Item -ItemType Directory -Force -Path (Join-Path $mjDir 'backup') | Out-Null
$mj = Join-Path $mjDir 'majestic.json'
[IO.File]::WriteAllText($mj, '{"cachePath":"C:\\x"}')
$arc = Join-Path $sandbox 'vanilla_backup_archive\2020-01-01_000000'
New-Item -ItemType Directory -Force -Path $arc | Out-Null
[IO.File]::WriteAllText((Join-Path $arc 'update.rpf.bin'), 'OLD-ARCHIVE')
$liveBin = Join-Path $mjDir 'backup\update.rpf.bin'
[IO.File]::WriteAllText($liveBin, 'FRESH-LAUNCHER')
$cfgB = @{ majesticJson = $mj }
$r = Restore-VanillaBackup -Cfg $cfgB
if ((-not $r) -and ([IO.File]::ReadAllText($liveBin) -eq 'FRESH-LAUNCHER')) { Good 'bins: fresh launcher bin is never downgraded' } else { Bad 'bins: stale archive overwrote a fresh bin' }
Remove-Item $liveBin -Force
if ((Restore-VanillaBackup -Cfg $cfgB) -and (Test-Path $liveBin)) { Good 'bins: missing bin restored from archive' } else { Bad 'bins: missing bin not restored' }

# 11d. Archive-VanillaBins: copies bins (never moves), prunes old generations
$g2 = Get-MgConfig
if (-not $g2.docsRoot) { }   # no-op, config sanity
$arcR = Join-Path $sandbox 'vanilla_backup_archive'
[IO.File]::WriteAllText($liveBin, 'FRESH-LAUNCHER')
if ((Archive-VanillaBins -Cfg $cfgB) -and (Test-Path "$arcR") -and (Test-Path $liveBin) -and ((Get-Content $liveBin -Raw) -eq 'FRESH-LAUNCHER')) {
    Good 'bins: archive created, original kept (copy-only)'
} else { Bad 'bins: Archive-VanillaBins failed or moved the original' }
$gen1 = @(Get-ChildItem $arcR -Directory)[0].Name
Start-Sleep -Milliseconds 1100   # timestamped dirs need distinct names
[IO.File]::WriteAllText($liveBin, 'SECOND-GEN')
Archive-VanillaBins -Cfg $cfgB | Out-Null
$gen2 = @(Get-ChildItem $arcR -Directory | Sort-Object Name -Descending)[0].Name
if ($gen2 -ne $gen1) { Good 'bins: second archive generation created' } else { Bad 'bins: second generation not created' }
# prune: Keep=1 must delete the older generation
Archive-VanillaBins -Cfg $cfgB -Keep 1 | Out-Null
$left = @(Get-ChildItem $arcR -Directory).Count
if ($left -eq 1) { Good 'bins: archive retention prunes old generations' } else { Bad "bins: retention left $left generations" }

# 11e. Prune-BackupFiles: keeps newest N, removes the rest
for ($i = 0; $i -lt 12; $i++) {
    [IO.File]::WriteAllText((Join-Path $sandbox ("settings.golden.xml.old_2020-01-01_0000{0:d2}" -f $i)), 'x')
    Start-Sleep -Milliseconds 30   # distinct LastWriteTime for deterministic sorting
}
Prune-BackupFiles -Pattern 'settings.golden.xml.old_*' -Keep 10
$leftBackups = @(Get-ChildItem $sandbox -Filter 'settings.golden.xml.old_*' -File).Count
if ($leftBackups -eq 10) { Good 'backups: retention keeps the newest 10' } else { Bad "backups: retention left $leftBackups" }

# 12. regression guards on the watcher source
$wtxt = Get-Content (Join-Path $repo 'gta-settings-watcher.ps1') -Raw
if ($wtxt -match '-not\s+\(Test-SameSettings') { Bad 'watcher: tri-state result used with -not (unreadable becomes drift)' }
if ($wtxt -match 'sessionReapplied\s*=\s*\$true') { Bad 'watcher: the adopt-blocking flag is back' }
if ($wtxt -notmatch '\}\s*finally\s*\{') { Bad 'watcher: $wasRunning must be updated in a finally block' }
if ($wtxt -notmatch 'appliedThisSession') { Bad 'watcher: adopt must require a successful apply this session' }
if ($wtxt -notmatch 'Test-AdoptCandidate[^\r\n]*\$appliedThisSession') { Bad 'watcher: adopt call does not pass the applied flag' }
$repTxt = Get-Content (Join-Path $repo 'repair.ps1') -Raw
if ($repTxt -match 'gta-settings-watcher\|MG_Helper') { Bad 'repair: loose alive-check pattern is back (matches itself)' }
$ctxt = Get-Content (Join-Path $repo 'common.ps1') -Raw
if ($wtxt -notmatch 'Archive-VanillaBins') { Bad 'watcher: vanilla bin archive is not built at exit (1002 insurance is a no-op)' }
$restTxt = Get-Content (Join-Path $repo 'restore-mg-snapshot.ps1') -Raw
if ($restTxt -notmatch 'mapping\.ContainsKey\(\$_\.Name\)') { Bad 'restore: manifest must filter unmapped (legacy/stale) files' }
if ($restTxt -notmatch '\^f\\d\+\\\.json\$') { Bad 'restore: new-format fallback must return null, not fN.json' }
if ($wtxt -match 'function Snapshot-MgFiles') { Bad 'watcher: must use common.ps1 Snapshot-MgFiles (round-trip testable), not a local copy' }
if ($ctxt -notmatch 'function Get-LatestBinArchive') { Bad 'common: Get-LatestBinArchive missing' }
if ($ctxt -match 'Select-Object -First 1[\s\S]{0,200}vanilla_backup_archive') { Bad 'common: latest-only bin archive selection is back' }
if ($ctxt -notmatch '\^\(powershell\|pwsh\|explorer\)') { Bad 'common: explorer process is not excluded from game matching' }
if ($ctxt -match 'TotalSeconds -lt 60') { Bad 'common: CIM cache TTL must be 20 s (60 s lagged renamed-exe detection)' }
if ($ctxt -notmatch '\[NullString\]::Value') { Bad 'common: [IO.File]::Replace without [NullString]::Value (PS 5.1 throws -> silent non-atomic fallback)' }
# reviewer round-4 regressions
foreach ($pf in 'max-fps.ps1', 'cut-shadows.ps1') {
    $ptxt = Get-Content (Join-Path $repo $pf) -Raw
    if ($ptxt -match 'WriteAllText\(\$file, \$bytes') { Bad "${pf}: WriteAllText(byte[]) writes decimal-garbage (must be WriteAllBytes)" }
    if ($ptxt -notmatch 'WriteAllBytes\(\$file, \$bytes\)') { Bad "${pf}: no WriteAllBytes fallback" }
    if ($ptxt -notmatch 'RegexOptions\]::IgnoreCase') { Bad "${pf}: merge is case-sensitive (-match ci vs Replace cs mismatch)" }
    if ($ptxt -notmatch '\$new2 -ne \$s') { Bad "${pf}: counter must count real replacements" }
}
if ($wtxt -notmatch 'new game PID') { Bad 'watcher: fast-relaunch new-PID detection missing' }
if ($wtxt -notmatch 'PID reuse guard') { Bad 'watcher: takeover does not verify the PID belongs to the game' }
if ($wtxt -notmatch 'Write-Atomic -Path \$Golden -Bytes \$adoptBytes') { Bad 'watcher: adopt must write golden atomically' }
if ((Get-Content (Join-Path $repo 'MG-Helper-Host.cs') -Raw) -notmatch '-Smoke') { Bad 'host: -Smoke mutex bypass missing (installer smoke would false-pass)' }
# MG-CR guards (round 5)
if ($ctxt -notmatch 'function XmlReaderSettings' -and $ctxt -notmatch 'XmlReaderSettings') { Bad 'common: Test-ValidSettingsXml must do real XML validation (MG-CR-003)' }
if ($ctxt -match 'Remove-Item -LiteralPath \$script:ConfigFile') { Bad 'common: Save-MgConfig still has the DESTRUCTIVE fallback (MG-CR-001)' }
if ($wtxt -notmatch 'UnknownSession') { Bad 'watcher: safe UnknownSession mode missing (MG-CR-004)' }
if ($wtxt -notmatch 'pre-apply backup FAILED') { Bad 'watcher: pre-apply backup failure must block the golden apply (MG-CR-006)' }
if ((Get-Content (Join-Path $repo 'install-gta-watcher.ps1') -Raw) -notmatch 'FALLBACK: 10-min repeat only') { Bad 'installer: schtasks fallback must be verified and honestly reported (MG-CR-007)' }
# MG-CR-008..012 guards (round 6)
$rstTxt = Get-Content (Join-Path $repo 'reset-settings.ps1') -Raw
if ($rstTxt -match 'Copy-Item \$Settings \$Golden') { Bad 'reset-settings: non-atomic golden write is back (MG-CR-008)' }
if ($rstTxt -notmatch 'Test-GoldenValid \$Golden') { Bad 'reset-settings: new golden not verified after write (MG-CR-008)' }
foreach ($pf in 'max-fps.ps1', 'cut-shadows.ps1') {
    $ptxt = Get-Content (Join-Path $repo $pf) -Raw
    if ($ptxt -notmatch 'ROLLED BACK') { Bad "${pf}: no transactional rollback of golden (MG-CR-009)" }
}
$repTxt2 = Get-Content (Join-Path $repo 'repair.ps1') -Raw
if ($repTxt2 -notmatch 'Восстановить эталон из текущих настроек') { Bad 'repair: LIVE-settings heal must ask for confirmation (MG-CR-010)' }
$diaTxt = Get-Content (Join-Path $repo 'diagnose.ps1') -Raw
if ($diaTxt -notmatch '<USER>') { Bad 'diagnose: report must mask the username by default (MG-CR-011)' }
$uniTxt = Get-Content (Join-Path $repo 'uninstall.ps1') -Raw
if ($uniTxt -notmatch 'РЕЗУЛЬТАТ УДАЛЕНИЯ') { Bad 'uninstall: per-action summary missing (MG-CR-012)' }
# MG-CR-013..022 guards (round 7)
if ($ctxt -notmatch 'OuterXml -eq \$db\.DocumentElement\.OuterXml') { Bad 'common: Test-SameSettings must do structural XML compare (MG-CR-015)' }
if ($wtxt -notmatch 'watcher\.ready') { Bad 'watcher: READY handshake marker missing (MG-CR-021)' }
if ($wtxt -notmatch 'gamePath') { Bad 'watcher: takeover must verify the game exe path (MG-CR-014)' }
if ($wtxt -notmatch 'state\.json save FAILED') { Bad 'watcher: Save-State failures must be logged (MG-CR-016)' }
$instTxt3 = Get-Content (Join-Path $repo 'install-gta-watcher.ps1') -Raw
if ($instTxt3 -notmatch '\.staging-') { Bad 'installer: staged deployment missing (MG-CR-019)' }
if ($instTxt3 -notmatch 'package_hashes\.txt') { Bad 'installer: SHA256 manifest of deployed files missing (MG-CR-017)' }
if ($instTxt3 -match 'Write-Host "\[i\] config\.json written[^"]*"[^}]*[\r\n]+\s*}') { }   # ok: inside else
if ($instTxt3 -notmatch 'READY marker') { Bad 'installer: must wait for the watcher READY marker (MG-CR-021)' }
foreach ($pf in 'max-fps.ps1', 'cut-shadows.ps1') {
    $ptxt = Get-Content (Join-Path $repo $pf) -Raw
    if ($ptxt -notmatch 'ОТКАТ НЕ УДАЛОСЬ ПОДТВЕРДИТЬ') { Bad "${pf}: rollback result must be verified (MG-CR-022)" }
    if ($ptxt -notmatch 'before the transaction starts') { Bad "${pf}: backup existence must be checked before the transaction (MG-CR-022)" }
}
# REVIEW.md rounds 1-2 guards
$ctxt = Get-Content (Join-Path $repo 'common.ps1') -Raw
if ($ctxt -notmatch 'function Get-WatcherProcess') { Bad 'common: shared Get-WatcherProcess missing (REVIEW-#9)' }
if ($ctxt -notmatch '\.incomplete') { Bad 'common: torn-generation .incomplete marker missing (REVIEW-#19)' }
if ($ctxt -notmatch 'OperationTimeoutSec 15') { Bad 'common: CIM calls need -OperationTimeoutSec 15 (REVIEW-#22)' }
$wtxt = Get-Content (Join-Path $repo 'gta-settings-watcher.ps1') -Raw
if ($wtxt -notmatch 'not \$adopted -and \$appliedThisSession') { Bad 'watcher: exit-restore must require appliedThisSession (REVIEW-#3)' }
if ($wtxt -notmatch 'exit handling deferred') { Bad 'watcher: exit-branch recheck after the 3 s wait missing (REVIEW-#21)' }
if ($wtxt -notmatch 'state\.json save FAILED') { Bad 'watcher: Save-State failures must be logged (REVIEW-#16)' }
if ($wtxt -notmatch 'StopCheck') { Bad 'watcher: Archive-VanillaBins must honour the stop event mid-copy (REVIEW-#19)' }
if ($wtxt -notmatch 'dlccache_backup' -or -not ($wtxt -match 'Select-Object -Skip 5')) { Bad 'watcher: dlccache_backup retention missing (REVIEW-#10)' }
$uniTxt2 = Get-Content (Join-Path $repo 'uninstall.ps1') -Raw
if ($uniTxt2 -notmatch 'exit 1') { Bad 'uninstall: must exit 1 when incomplete (REVIEW-#20)' }
$mgTxt = Get-Content (Join-Path $repo 'MG-Helper.ps1') -Raw
if ($mgTxt -notmatch 'LASTEXITCODE') { Bad 'menu: uninstall result must be checked (REVIEW-#20)' }
# ROADMAP phase 1-2 guards
if ($ctxt -notmatch 'function Start-OpJournal') { Bad 'common: operation journal missing (ROADMAP 2.1)' }
if ($ctxt -notmatch 'function Invoke-OpReconciliation') { Bad 'common: reconciliation missing (ROADMAP 2.1)' }
$wtxt = Get-Content (Join-Path $repo 'gta-settings-watcher.ps1') -Raw
if ($wtxt -notmatch 'events\.jsonl') { Bad 'watcher: structured events.jsonl missing (ROADMAP 3.1)' }
if ($wtxt -notmatch 'FileSystemWatcher') { Bad 'watcher: FSW hybrid missing (ROADMAP 1.1)' }
if ($wtxt -notmatch 'Invoke-OpReconciliation') { Bad 'watcher: reconciliation not called at start (ROADMAP 2.1)' }
foreach ($hf in 'CHANGELOG.md', '.gitattributes', 'PSScriptAnalyzerSettings.psd1') {
    if (-not (Test-Path (Join-Path $repo $hf))) { Bad "repo hygiene: $hf missing" }
}
# ROADMAP phase 3-5 completion guards (v2.4.0)
if (-not (Test-Path (Join-Path $repo 'tests\MGHelper.Tests.ps1'))) { Bad 'repo: Pester suite tests\MGHelper.Tests.ps1 missing (ROADMAP 4.1)' }
$pesterTxt = Get-Content (Join-Path $repo 'tests\MGHelper.Tests.ps1') -Raw
if ($pesterTxt -notmatch 'Describe') { Bad 'pester: no Describe blocks' }
$ciTxt = Get-Content (Join-Path $repo '.github\workflows\ci.yml') -Raw
foreach ($needle in 'check\.ps1', 'Invoke-Pester', 'PSScriptAnalyzer') {
    if ($ciTxt -notmatch $needle) { Bad "ci.yml: missing '$needle' (ROADMAP 4.1)" }
}
$mgTxt2 = Get-Content (Join-Path $repo 'MG-Helper.ps1') -Raw
if ($mgTxt2 -notmatch 'Show-Onboarding') { Bad 'menu: onboarding wizard missing (ROADMAP 5.5)' }
$cfgTxt = Get-Content (Join-Path $repo 'common.ps1') -Raw
if ($cfgTxt -notmatch 'autoUpdate') { Bad 'common: autoUpdate config flag missing (ROADMAP 5.2)' }
if ($wtxt -notmatch 'auto-update') { Bad 'watcher: opt-in silent auto-update missing (ROADMAP 5.2)' }
# ROADMAP phase 2-4 guards (v2.2.0)
if (-not (Test-Path (Join-Path $repo 'MG-Helper-Tray.cs'))) { Bad 'repo: MG-Helper-Tray.cs missing (ROADMAP 5.1)' }
$trayTxt = Get-Content (Join-Path $repo 'MG-Helper-Tray.cs') -Raw
foreach ($needle in 'NotifyIcon', 'watcher.ready', 'events.jsonl', 'ShowBalloonTip') {
    if ($trayTxt -notmatch $needle) { Bad "tray: missing '$needle' (ROADMAP 5.1/3.2)" }
}
$instTxt4 = Get-Content (Join-Path $repo 'install-gta-watcher.ps1') -Raw
foreach ($needle in 'MG-Helper-Tray\.cs', 'MG Helper Tray\.lnk', 'MG-Helper-Tray\.exe') {
    if ($instTxt4 -notmatch $needle) { Bad "installer: tray piece missing '$needle' (ROADMAP 5.1)" }
}
if (-not (Test-Path (Join-Path $repo 'update-helper.ps1'))) { Bad 'repo: update-helper.ps1 missing (ROADMAP 5.2)' }
$updTxt = Get-Content (Join-Path $repo 'update-helper.ps1') -Raw
foreach ($needle in 'SHA256', 'Get-FileHash', 'install-gta-watcher\.ps1') {
    if ($updTxt -notmatch $needle) { Bad "update: missing '$needle' (ROADMAP 5.2)" }
}
if ($wtxt -notmatch 'config reloaded') { Bad 'watcher: config reload on heartbeat missing (REVIEW-#7)' }
$depList = [regex]::Match((Get-Content (Join-Path $repo 'install-gta-watcher.ps1') -Raw), '\$deploy\s*=\s*@\(([^)]*)\)').Groups[1].Value
foreach ($need in 'MG-Helper-Tray\.cs', 'update-helper\.ps1') {
    if ($depList -notmatch $need) { Bad "installer deploy list missing $need" }
}
# ROADMAP 2.3: golden key pure decision matrix
if (Test-GoldenKeyMatchPure 'GTA V' 'gpuA' 'GTA V' 'gpuA') { Good 'golden-key: identical setup matches' } else { Bad 'golden-key: identical setup mismatched' }
if (-not (Test-GoldenKeyMatchPure 'GTA V' 'gpuA' 'GTA V Enhanced' 'gpuA')) { Good 'golden-key: game variant change detected' } else { Bad 'golden-key: variant change missed' }
if (-not (Test-GoldenKeyMatchPure 'GTA V' 'gpuA' 'GTA V' 'gpuB')) { Good 'golden-key: GPU change detected' } else { Bad 'golden-key: GPU change missed' }
if ($null -eq (Test-GoldenKeyMatchPure '' '' 'GTA V' 'gpuA')) { Good 'golden-key: no recorded key -> conservative match' } else { Bad 'golden-key: missing key mishandled' }
if ($null -eq (Test-GoldenKeyMatchPure 'GTA V' 'gpuA' '' '')) { Good 'golden-key: unreadable current identity -> conservative match' } else { Bad 'golden-key: unreadable identity mishandled' }
if ($wtxt -notmatch 'goldenMismatch') { Bad 'watcher: golden key mismatch gate missing (ROADMAP 2.3)' }
if ($wtxt -notmatch 'Save-GoldenKey|Get-SavedGoldenKey') { Bad 'watcher: golden key backfill missing' }
# ROADMAP 2.4: snapshot generations
if ($ctxt -notmatch 'genDir = Join-Path \$snapRoot \(Get-Date') { Bad 'common: Snapshot-MgFiles must write timestamped generations (ROADMAP 2.4)' }
$oldSnap = Join-Path $sandbox 'mg_snapshot'
$gensSnap = @(Get-ChildItem $oldSnap -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') })
if ($gensSnap.Count -gt 0) { Good 'snapshot: generations layout present after round-trip' } else { Bad 'snapshot: generations layout missing' }

# 11m. MG-CR-003: XML validation rejects torn/partial/wrong-root files
$vx = Join-Path $sandbox 'valid_settings.xml'
[IO.File]::WriteAllText($vx, "<?xml version=`"1.0`"?><Settings><graphics/><audio/></Settings>")
if (Test-ValidSettingsXml $vx) { Good 'xml: valid Settings file accepted' } else { Bad 'xml: valid file rejected' }
[IO.File]::WriteAllText($vx, '<Settings><graphics/>')   # torn, no closing tag
if (-not (Test-ValidSettingsXml $vx)) { Good 'xml: torn file rejected' } else { Bad 'xml: torn file accepted' }
[IO.File]::WriteAllText($vx, '<?xml version="1.0"?><NotSettings/>')
if (-not (Test-ValidSettingsXml $vx)) { Good 'xml: wrong root rejected' } else { Bad 'xml: wrong root accepted' }
[IO.File]::WriteAllText($vx, '<Settings><graphics/></Settings><!-- $1 -->')
if (Test-ValidSettingsXml $vx) { Good 'xml: $digit inside comment no longer a false rejection' } else { Bad 'xml: comment content false-rejected' }

# 11n. MG-CR-002: Apply-Golden heals from the validated source and applies its bytes
$sbx = Join-Path $sandbox 'apply'
New-Item -ItemType Directory -Force -Path $sbx | Out-Null
$gGolden = Join-Path $sbx 'settings.golden.xml'
$gBak = Join-Path $sbx 'settings.before_apply.bak'
$gLive = Join-Path $sbx 'live_settings.xml'
[IO.File]::WriteAllText($gGolden, 'TORN-GARBAGE-NOT-XML')
[IO.File]::WriteAllText($gBak, "<?xml version=`"1.0`"?><Settings><golden>" + ('x' * 100) + "</golden></Settings>")
[IO.File]::WriteAllText($gLive, 'OLD-LIVE')
$script:HelperDir = $sbx
$cfgA = @{ settingsXml = $gLive }
$okA = Apply-Golden -Cfg $cfgA
$liveOk = ([IO.File]::ReadAllText($gLive) -match '<golden>x{100}</golden>')
$goldenOk = (Test-GoldenValid $gGolden)
if ($okA -and $liveOk -and $goldenOk) { Good 'apply-golden: heals from validated source, applies same bytes, golden verified' } else { Bad "apply-golden: ok=$okA live=$liveOk goldenOk=$goldenOk" }
$script:HelperDir = $sandbox

# 11o. MG-CR-001: Save-MgConfig failure leaves the old config intact
$cfgHold = Get-MgConfig
$cfgHold.settingsXml = 'C:\preserved\value.xml'
Save-MgConfig $cfgHold | Out-Null
$before = Get-Content -LiteralPath $script:ConfigFile -Raw
$lockCfg = [IO.File]::Open($script:ConfigFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
$cfgHold.settingsXml = 'C:\changed\value.xml'
$rSave = Save-MgConfig $cfgHold
$lockCfg.Close(); $lockCfg.Dispose()
$after = Get-Content -LiteralPath $script:ConfigFile -Raw
if ((-not $rSave) -and ($after -eq $before)) { Good 'config: failed save returns $false and PRESERVES the old config' } else { Bad "config: failed save rSave=$rSave preserved=$($after -eq $before)" }

# 11p. MG-CR-005: Ensure-BinsRestored reports partial when a source is locked
$mjP = Join-Path $sandbox 'maj_p'
New-Item -ItemType Directory -Force -Path (Join-Path $mjP 'backup') | Out-Null
$mjPJson = Join-Path $mjP 'majestic.json'
[IO.File]::WriteAllText($mjPJson, '{"cachePath":"C:\\x"}')
$arcP = Join-Path $sandbox 'vanilla_backup_archive\2098-01-01_000000'
New-Item -ItemType Directory -Force -Path $arcP | Out-Null
[IO.File]::WriteAllText((Join-Path $arcP 'a.bin'), 'AAAA')
[IO.File]::WriteAllText((Join-Path $arcP 'b.bin'), 'BBBB')
$oldBk = $script:HelperDir; $script:HelperDir = $sandbox
$st1 = Ensure-BinsRestored -Cfg @{ majesticJson = $mjPJson }
$lockP = [IO.File]::Open((Join-Path $arcP 'a.bin'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
Remove-Item (Join-Path $mjP 'backup\a.bin') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $mjP 'backup\b.bin') -Force -ErrorAction SilentlyContinue
$st2 = Ensure-BinsRestored -Cfg @{ majesticJson = $mjPJson }
$lockP.Close(); $lockP.Dispose()
if ($st1 -eq 'restored' -and $st2 -eq 'partial') { Good 'bins-ensure: partial status on a locked source' } else { Bad "bins-ensure: st1=$st1 st2=$st2 (expected restored/partial)" }
# REVIEW-#2: a partial restore CONTINUES on the next tick (the old code saw
# "at least one bin" and never finished)
$st3 = Ensure-BinsRestored -Cfg @{ majesticJson = $mjPJson }
if ($st3 -eq 'restored' -and (Test-Path (Join-Path $mjP 'backup\a.bin'))) { Good 'bins-ensure: partial restore continues on the next tick' } else { Bad "bins-ensure: partial never finished (st3=$st3)" }
$script:HelperDir = $oldBk

# 11q. ROADMAP 2.1: journal + reconciliation rolls the golden back
$jBak = Join-Path $sandbox 'journal_bak.xml'
[IO.File]::WriteAllText($jBak, "<?xml version=`"1.0`"?><Settings><journal-bak>" + ('x' * 100) + "</journal-bak></Settings>")
$goldenPath = Join-Path $script:HelperDir 'settings.golden.xml'
[IO.File]::WriteAllText($goldenPath, 'TORN-MID-OP')
Start-OpJournal 'profile-test'
Set-OpJournalStep 'profile-test' 'backup' 'done' $jBak
Set-OpJournalStep 'profile-test' 'write-golden' 'done' $goldenPath
$oldBk2 = $script:HelperDir; $script:HelperDir = $sandbox
Invoke-OpReconciliation
$script:HelperDir = $oldBk2
$jState = (Get-Content (Get-OpJournalPath 'profile-test') -Raw | ConvertFrom-Json).status
if ((Test-GoldenValid $goldenPath) -and ([IO.File]::ReadAllText($goldenPath) -match '<journal-bak>') -and ($jState -eq 'recovered')) {
    Good 'journal: reconciliation rolled the golden back and marked the op recovered'
} else { Bad "journal: reconciliation failed (goldenValid=$(Test-GoldenValid $goldenPath) state=$jState)" }

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
    if ($instTxt2 -notmatch 'host smoke') { Bad 'installer: hidden host is not smoke-run (AppLocker/AV would silently break the task)' }
}
$wtxt2 = Get-Content (Join-Path $repo 'gta-settings-watcher.ps1') -Raw
if ($wtxt2 -notmatch 'restartPending') { Bad 'watcher: self-restart is not deferred during game sessions' }
if ($wtxt2 -match 'Start-Process\s+\$psExe') { Bad 'watcher: direct powershell spawn remains (use the hidden host)' }

# 11f. Archive-VanillaBins: a locked bin must not create an empty "latest" generation
$cfgF = @{ majesticJson = $mj }   # $mj from section 11c
$goodArc = Join-Path $sandbox 'vanilla_backup_archive\2099-01-01_000000'
New-Item -ItemType Directory -Force -Path $goodArc | Out-Null
[IO.File]::WriteAllText((Join-Path $goodArc 'update.rpf.bin'), 'GOOD-GEN')
$liveF = Join-Path $mjDir 'backup\update.rpf.bin'
[IO.File]::WriteAllText($liveF, 'LIVE-CONTENT')
$gensBefore = @(Get-ChildItem (Join-Path $sandbox 'vanilla_backup_archive') -Directory).Count
$lock = [IO.File]::Open($liveF, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
$rF = Archive-VanillaBins -Cfg $cfgF
$lock.Close(); $lock.Dispose()
$gensAfter = @(Get-ChildItem (Join-Path $sandbox 'vanilla_backup_archive') -Directory).Count
if ((-not $rF) -and ($gensAfter -eq $gensBefore)) { Good 'archive: locked bin -> no empty generation' }
else {
    Write-Host ("    [dbg 11f] rF=$rF before=$gensBefore after=$gensAfter") -ForegroundColor DarkGray
    Get-ChildItem (Join-Path $sandbox 'vanilla_backup_archive') -Directory | ForEach-Object {
        Write-Host ("    [dbg 11f] gen " + $_.Name + " files=" + @(Get-ChildItem $_.FullName -Filter '*.bin').Count) -ForegroundColor DarkGray
    }
    Bad 'archive: torn generation became latest'
}
if (Get-LatestBinArchive) { Good 'archive: helper still finds the good generation' } else { Bad 'archive: helper lost the good generation' }

# 11g. unchanged bins -> no new generation (skip the multi-GB copy)
[IO.File]::WriteAllText((Join-Path $goodArc 'update.rpf.bin'), 'LIVE-CONTENT')
(Get-Item (Join-Path $goodArc 'update.rpf.bin')).LastWriteTimeUtc = (Get-Item $liveF).LastWriteTimeUtc
$rG = Archive-VanillaBins -Cfg $cfgF
$gensG = @(Get-ChildItem (Join-Path $sandbox 'vanilla_backup_archive') -Directory).Count
if ((-not $rG) -and ($gensG -le $gensAfter)) { Good 'archive: unchanged bins skip the copy (no new generation)' }
else {
    Write-Host ("    [dbg 11g] rG=$rG gensG=$gensG gensAfter=$gensAfter") -ForegroundColor DarkGray
    Get-ChildItem (Join-Path $sandbox 'vanilla_backup_archive') -Directory | ForEach-Object {
        Write-Host ("    [dbg 11g] gen " + $_.Name + " files=" + @(Get-ChildItem $_.FullName -Filter '*.bin').Count) -ForegroundColor DarkGray
    }
    Bad 'archive: unchanged bins re-copied'
}

# 11h. changed bins -> fresh verified generation
[IO.File]::WriteAllText($liveF, 'LIVE-CONTENT-V2')
$rH = Archive-VanillaBins -Cfg $cfgF
if ($rH) { Good 'archive: changed bins archived' } else { Bad 'archive: changed bins not archived' }

# 11i. Get-LatestBinArchive skips an empty newest generation
$emptyGen = Join-Path $sandbox 'vanilla_backup_archive\2030-01-01_000000'
New-Item -ItemType Directory -Force -Path $emptyGen | Out-Null
$arcI = Get-LatestBinArchive
if ($arcI -and ($arcI.dir.Name -ne '2030-01-01_000000')) { Good 'archive: empty newest generation skipped' } else { Bad 'archive: empty generation treated as latest' }
Remove-Item $emptyGen -Recurse -Force

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host ''; Write-Host 'ERRORS FOUND - do not commit.' -ForegroundColor Red; exit 1 }
Write-Host ''; Write-Host 'ALL GREEN - safe to commit.' -ForegroundColor Green
exit 0
