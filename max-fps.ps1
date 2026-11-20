# MAX FPS graphics profile - by Bayra & Kavel1n
# Applies the highest-FPS graphics values to golden + current settings.
# Video block (resolution/GPU) is never touched. Backup kept.
# Universal v5: golden lives in %LOCALAPPDATA%\MG_Helper, paths from config.json.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MAX FPS Profile - by Bayra & Kavel1n'

$HelperDir  = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden     = Join-Path $HelperDir 'settings.golden.xml'
$ConfigFile = Join-Path $HelperDir 'config.json'

# --- load universal discovery when available ---
$common = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'common.ps1'))) {
    $common = Join-Path $PSScriptRoot 'common.ps1'
} elseif (Test-Path -LiteralPath (Join-Path $HelperDir 'common.ps1')) {
    $common = Join-Path $HelperDir 'common.ps1'
}
if ($common) { . $common } else {
    function Find-SettingsXml {
        foreach ($d in @([Environment]::GetFolderPath('MyDocuments'), "$env:USERPROFILE\OneDrive\Documents", "$env:USERPROFILE\Documents")) {
            $c = Join-Path $d 'Rockstar Games\GTA V\settings.xml'
            if (Test-Path $c) { return $c }
        }
        return $null
    }
}

$Settings = $null
if (Test-Path $ConfigFile) {
    try { $cfg = Get-Content $ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $cfg = $null }
    if ($cfg -and $cfg.settingsXml -and (Test-Path -LiteralPath $cfg.settingsXml)) { $Settings = $cfg.settingsXml }
}
if (-not $Settings) { $Settings = Find-SettingsXml }

if (-not ((Test-Path $Golden) -and (Test-Path $Settings))) {
    Write-Host "[!] golden or settings.xml not found" -ForegroundColor Red
    Write-Host "    Run MG-Helper.bat -> [1] first, or check the paths in $ConfigFile" -ForegroundColor DarkGray
    exit 1
}

# refuse to fight a running game: it holds settings.xml and rewrites it on exit
$gameProcs = @('GTA5', 'GTA5_Enhanced')
if (Get-Command Find-MatchingProcess -ErrorAction SilentlyContinue) {
    $gameRunning = [bool](Find-MatchingProcess -Patterns $gameProcs)
} else {
    $gameRunning = [bool](Get-Process -Name $gameProcs -ErrorAction SilentlyContinue)
}
if ($gameRunning) {
    Write-Host "[!] GTA V is running - close the game first, then apply again." -ForegroundColor Red
    exit 1
}

$values = [ordered]@{
    'Tessellation'                  = '0'
    'LodScale'                      = '0.000000'
    'PedLodBias'                    = '-0.500000'
    'VehicleLodBias'                = '-0.500000'
    'ShadowQuality'                 = '0'
    'ReflectionQuality'             = '0'
    'ReflectionMSAA'                = '0'
    'SSAO'                          = '0'
    'AnisotropicFiltering'          = '0'
    'MSAA'                          = '0'
    'MSAAFragments'                 = '0'
    'MSAAQuality'                   = '0'
    'SamplingMode'                  = '0'
    'TextureQuality'                = '0'
    'ParticleQuality'               = '0'
    'WaterQuality'                  = '0'
    'GrassQuality'                  = '0'
    'ShaderQuality'                 = '0'
    'Shadow_SoftShadows'            = '0'
    'UltraShadows_Enabled'          = 'false'
    'Shadow_ParticleShadows'        = 'false'
    'Shadow_Distance'               = '1.000000'
    'Shadow_LongShadows'            = 'false'
    'Shadow_SplitZStart'            = '0.930000'
    'Shadow_SplitZEnd'              = '0.890000'
    'Shadow_aircraftExpWeight'      = '-3.000000'
    'Shadow_DisableScreenSizeCheck' = 'false'
    'Reflection_MipBlur'            = 'false'
    'FXAA_Enabled'                  = 'false'
    'TXAA_Enabled'                  = 'false'
    'Lighting_FogVolumes'           = 'false'
    'Shader_SSA'                    = 'false'
    'DX_Version'                    = '2'
    'CityDensity'                   = '0.000000'
    'PedVarietyMultiplier'          = '0.000000'
    'VehicleVarietyMultiplier'      = '0.000000'
    'PostFX'                        = '0'
    'DoF'                           = 'false'
    'HdStreamingInFlight'           = 'false'
    'MaxLodScale'                   = '0.000000'
    'MotionBlurStrength'            = '0.000000'
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Copy-Item $Golden (Join-Path $HelperDir "settings.golden.xml.before_maxfps_$stamp") -Force
Copy-Item $Settings (Join-Path $HelperDir "settings.xml.before_maxfps_$stamp") -Force
if (Get-Command Prune-BackupFiles -ErrorAction SilentlyContinue) {
    Prune-BackupFiles -Pattern 'settings.*before_maxfps_*'   # keep the newest 10, prune the rest
}

# phase 1: merge + validate BOTH files before touching anything
$merged = @{}
foreach ($file in @($Golden, $Settings)) {
    $s = Get-Content $file -Raw
    $n = 0
    foreach ($k in $values.Keys) {
        $pattern = "(?<=<$k value=`")[^`"]*(?=`")"
        # case-insensitive replace; counter counts REAL changes ('-match' is ci, [regex]::Replace was cs)
        $new2 = [regex]::Replace($s, $pattern, $values[$k], [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($new2 -ne $s) { $s = $new2; $n++ }
    }
    if ($s -match '\$\d') {
        Write-Host "[!] corrupt merge - aborted, nothing changed" -ForegroundColor Red
        exit 1
    }
    $merged[$file] = @{ text = $s; count = $n }
}
# ROADMAP 5.3: diff-preview per file + confirm before touching anything
Write-Host "[i] Изменения по файлам:"
$diffG = Show-SettingsDiff -OldText (Get-Content $Golden -Raw) -NewText $merged[$Golden].text -MaxLines 40
$diffS = Show-SettingsDiff -OldText (Get-Content $Settings -Raw) -NewText $merged[$Settings].text -MaxLines 40
if (($diffG -eq 0) -and ($diffS -eq 0)) { Write-Host "[i] Ни одного реального изменения - применять нечего." -ForegroundColor Yellow; exit 0 }
$rc = Read-Host "Применить этот профиль? (да/нет)"
if ($rc -notmatch '^(д|да|y|yes)$') { Write-Host "Отменено."; exit 0 }

# phase 2: atomic writes (retry + read-only handling live in Write-Atomic).
# MG-CR-009 + MG-CR-022: transactional - golden written FIRST, live second;
# if the live write fails, the golden is rolled back from its backup AND the
# rollback itself is verified before claiming anything. Backups must exist
# BEFORE the transaction starts.
$bkGoldenPath = Join-Path $HelperDir "settings.golden.xml.before_maxfps_$stamp"
$bkLivePath = Join-Path $HelperDir "settings.xml.before_maxfps_$stamp"
if (-not ((Test-Path -LiteralPath $bkGoldenPath) -and (Test-Path -LiteralPath $bkLivePath))) {
    Write-Host "[!] резервные копии не созданы - отмена, ничего не изменено." -ForegroundColor Red
    exit 1
}
# ROADMAP 2.1: journal the transaction so a kill mid-way is reconciled at next watcher start
Start-OpJournal 'profile-maxfps'
Set-OpJournalStep 'profile-maxfps' 'backup' 'done' $bkGoldenPath
$goldenWritten = $false
foreach ($file in @($Golden, $Settings)) {
    $bytes = [Text.UTF8Encoding]::new($true).GetBytes($merged[$file].text)
    $wok = $false
    if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) {
        $wok = Write-Atomic -Path $file -Bytes $bytes
    } else {
        try { [IO.File]::WriteAllBytes($file, $bytes); $wok = $true } catch { $wok = $false }   # byte[] -> WriteAllBytes, NOT WriteAllText
    }
    if (-not $wok) {
        Write-Host "[!] could not write $file (locked?)" -ForegroundColor Red
        if ($goldenWritten) {
            $rBytes = [IO.File]::ReadAllBytes($bkGoldenPath)
            $rOk = $false
            if (Get-Command Write-Atomic -ErrorAction SilentlyContinue) { $rOk = Write-Atomic -Path $Golden -Bytes $rBytes }
            else { try { [IO.File]::WriteAllBytes($Golden, $rBytes); $rOk = $true } catch { $rOk = $false } }
            # MG-CR-022: verify the rollback by re-reading, then report honestly
            $rVerify = $false
            try { $rVerify = (([IO.File]::ReadAllBytes($Golden)) -join ',') -eq ($rBytes -join ',') } catch { $rVerify = $false }
            Complete-OpJournal 'profile-maxfps' $(if ($rOk -and $rVerify) { 'rolled-back' } else { 'rollback-failed' })
            if ($rOk -and $rVerify) { Write-Host "[!] golden ROLLED BACK from backup - nothing changed." -ForegroundColor Yellow }
            else { Write-Host "[!] ОТКАТ НЕ УДАЛОСЬ ПОДТВЕРДИТЬ - эталон может содержать новый профиль. Восстанови вручную из $bkGoldenPath" -ForegroundColor Red }
        } else {
            Write-Host "[!] nothing was modified yet - aborting." -ForegroundColor Yellow
            Complete-OpJournal 'profile-maxfps' 'aborted'
        }
        exit 1
    }
    if ($file -eq $Golden) {
        $goldenWritten = $true
        Set-OpJournalStep 'profile-maxfps' 'write-golden' 'done' $Golden
    }
}
Complete-OpJournal 'profile-maxfps' 'done'

Write-Host "[+] MAX FPS applied (golden: $($merged[$Golden].count), settings: $($merged[$Settings].count) values)" -ForegroundColor Green
Write-Host "[+] Backups: settings.golden.xml.before_maxfps_$stamp / settings.xml.before_maxfps_$stamp" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Trade-offs: empty streets, aggressive pop-in, no shadows/fx." -ForegroundColor Yellow
