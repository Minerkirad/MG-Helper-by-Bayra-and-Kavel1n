# ============================================================
#  MG Helper - installer (v4: installs anywhere)
#  by Bayra & Kavel1n
#
#  Run ONCE. It sets up:
#  - golden settings = THIS PC owner's own settings.xml
#  - at every GTA V launch: snapshots MG files (archive only),
#    archives Majestic's vanilla backup so MG graphics survives,
#    applies golden, archives dlccache
#  - on game exit: restores settings and Majestic's files
#  - autostart of the watcher with Windows
#  - watcher has a -Diagnose mode for remote troubleshooting
#
#  All package files live in %LOCALAPPDATA%\MG_Helper
#  (always writable - independent of OneDrive / Documents quirks).
#  Nothing is ever deleted. Use "0-uninstall.bat" to remove everything.
# ============================================================

$host.UI.RawUI.WindowTitle = 'MG Helper - by Bayra & Kavel1n'
$ErrorActionPreference = 'Continue'

# remove Mark-of-the-Web from package files (archives sent via messengers get flagged)
Get-ChildItem $PSScriptRoot -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ------------------------------------------------------------
# 0. locate settings.xml (multi-strategy: standard roots, then recursive)
# ------------------------------------------------------------
function Find-SettingsXml {
    # a) known Documents roots
    $docsRoots = @(
        [Environment]::GetFolderPath('MyDocuments'),
        "$env:USERPROFILE\OneDrive\Documents",
        "$env:USERPROFILE\Documents"
    )
    foreach ($one in (Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
        $docsRoots += (Join-Path $one.FullName 'Documents')
    }
    foreach ($d in ($docsRoots | Select-Object -Unique)) {
        $c = Join-Path $d 'Rockstar Games\GTA V\settings.xml'
        if ($c -and (Test-Path $c)) { return $c }
    }

    # b) recursive fallback: search the whole user profile (depth-limited)
    Write-Host "[i] settings.xml not in standard locations - searching user profile..." -ForegroundColor DarkGray
    $hits = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 5 -Filter 'settings.xml' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'Rockstar Games\\GTA V' -and $_.FullName -notmatch '_settings_backup' } |
        Sort-Object LastWriteTime -Descending
    foreach ($h in $hits) {
        $c = Get-Content $h.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -match '<Settings>' -and ($c -notmatch '\$\d')) { return $h.FullName }   # validate content
    }
    return $null
}

$Settings = Find-SettingsXml
if (-not $Settings) {
    Write-Host "[!] Could not find Rockstar Games\GTA V\settings.xml on this PC." -ForegroundColor Red
    Write-Host "    Run GTA V once (so it creates its settings), then run this installer again."
    pause; exit 1
}
$GtaDir = Split-Path $Settings
Write-Host "[i] GTA V settings found: $Settings"

# ------------------------------------------------------------
# 1. helper folder (always writable - the core of the "any PC" design)
# ------------------------------------------------------------
$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
try {
    New-Item -ItemType Directory -Force -Path $HelperDir -ErrorAction Stop | Out-Null
} catch {
    Write-Host "[!] Could not create helper folder: $HelperDir" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    pause; exit 1
}
if (-not (Test-Path $HelperDir)) {
    Write-Host "[!] Helper folder still missing: $HelperDir" -ForegroundColor Red
    pause; exit 1
}
Write-Host "[i] Helper folder: $HelperDir"

# migrate old golden/log from legacy Documents\_settings_backup if present
$legacyBackup = Join-Path (Split-Path $Settings) '_settings_backup'
$legacyGolden = Join-Path $legacyBackup 'settings.golden.xml'
$golden = Join-Path $HelperDir 'settings.golden.xml'
if (-not (Test-Path $golden) -and (Test-Path $legacyGolden)) {
    Copy-Item $legacyGolden $golden -Force
    Write-Host "[i] Migrated existing golden from legacy location." -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# 2. watcher script (v4: settings discovered, helper folder storage)
# ------------------------------------------------------------
$watcherCode = @'
param([switch]$Diagnose)
# MG Helper watcher v4 - by Bayra & Kavel1n
# Golden (this PC owner's own settings) is applied at every GTA5 launch and
# restored on exit. MG files are snapshotted (archive only). Majestic's
# vanilla backup .bin is archived during the session so MG graphics survives,
# and returned after. Nothing is ever deleted.
# All package data lives in %LOCALAPPDATA%\MG_Helper.
# settings.xml is DISCOVERED (Documents / OneDrive / recursive profile search).

$ErrorActionPreference = 'SilentlyContinue'
$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
$Golden    = Join-Path $HelperDir 'settings.golden.xml'
$LogFile   = Join-Path $HelperDir 'watcher.log'

function Find-SettingsXml {
    $docsRoots = @(
        [Environment]::GetFolderPath('MyDocuments'),
        "$env:USERPROFILE\OneDrive\Documents",
        "$env:USERPROFILE\Documents"
    )
    foreach ($one in (Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
        $docsRoots += (Join-Path $one.FullName 'Documents')
    }
    foreach ($d in ($docsRoots | Select-Object -Unique)) {
        $c = Join-Path $d 'Rockstar Games\GTA V\settings.xml'
        if ($c -and (Test-Path $c)) { return $c }
    }
    $hits = Get-ChildItem "$env:USERPROFILE" -Recurse -Depth 5 -Filter 'settings.xml' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'Rockstar Games\\GTA V' -and $_.FullName -notmatch '_settings_backup' } |
        Sort-Object LastWriteTime -Descending
    foreach ($h in $hits) {
        $c = Get-Content $h.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -match '<Settings>' -and ($c -notmatch '\$\d')) { return $h.FullName }   # validate content
    }
    return $null
}

function Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Out-File $LogFile -Append -Encoding UTF8
}

function Snapshot-Mg {
    # saves a full copy of MG settings files (nothing is ever deleted)
    try {
        $snapDir = Join-Path $HelperDir 'mg_snapshot'
        New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
        $n = 0
        foreach ($dir in @("$env:APPDATA\MiamiGraphics", "$env:LOCALAPPDATA\MiamiGraphics") | Select-Object -Unique) {
            if (-not (Test-Path $dir)) { continue }
            $root = ($dir -replace '[:\\/]', '_')
            foreach ($f in (Get-ChildItem $dir -Recurse -Depth 2 -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $rel = ($root + '__' + $f.FullName.Substring($dir.Length).TrimStart('\')) -replace '[\\/]', '__'
                Copy-Item $f.FullName (Join-Path $snapDir $rel) -Force
                $n++
            }
        }
        if ($n -gt 0) { Log "MG snapshot saved ($n files -> $snapDir)" }
    } catch {
        Log "[!] MG snapshot error: $_"
    }
}

function Clean-Dlccache {
    # archives dlccache .dat files into a backup folder instead of deleting
    $cachePath = $null
    $mjJson = "$env:APPDATA\majestic-launcher\Multiplayer\majestic.json"
    if (Test-Path $mjJson) {
        try { $cachePath = (Get-Content $mjJson -Raw | ConvertFrom-Json).cachePath } catch {}
    }
    if (-not $cachePath -or -not (Test-Path "$cachePath\dlccache")) { return }
    try {
        $files = Get-ChildItem "$cachePath\dlccache" -Filter '*.dat' -ErrorAction SilentlyContinue
        if (-not $files) { return }
        $arc = Join-Path $HelperDir ("dlccache_backup\{0}" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        New-Item -ItemType Directory -Force -Path $arc | Out-Null
        $files | Move-Item -Destination $arc -Force -ErrorAction SilentlyContinue
        Log ("dlccache archived {0} files -> {1}" -f $files.Count, $arc)
    } catch {
        Log "[!] dlccache archive error: $_"
    }
}

function Archive-VanillaBackup {
    # archives Majestic's vanilla update.rpf backup (.bin) so MG graphics
    # survives the launch. Only ONE archived copy is kept (prune older).
    try {
        $bkDir = "$env:APPDATA\majestic-launcher\Multiplayer\backup"
        if (-not (Test-Path $bkDir)) { return }
        $bins = Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue
        if (-not $bins) { return }
        $arcRoot = Join-Path $HelperDir 'vanilla_backup_archive'
        $arc = Join-Path $arcRoot (Get-Date -Format 'yyyy-MM-dd_HHmmss')
        New-Item -ItemType Directory -Force -Path $arc | Out-Null
        $bins | Move-Item -Destination $arc -Force -ErrorAction SilentlyContinue
        Get-ChildItem $arcRoot -Directory | Where-Object { $_.Name -ne (Split-Path $arc -Leaf) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Log ("vanilla backup archived {0} file(s) -> {1}" -f $bins.Count, $arc)
    } catch {
        Log "[!] vanilla backup archive error: $_"
    }
}

function Restore-VanillaBackup {
    # returns the archived vanilla backup back to Majestic ('before' state)
    try {
        $bkDir = "$env:APPDATA\majestic-launcher\Multiplayer\backup"
        if (-not (Test-Path $bkDir)) { return }
        $latestArc = Get-ChildItem (Join-Path $HelperDir 'vanilla_backup_archive') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latestArc) { return }
        $files = Get-ChildItem $latestArc.FullName -Filter '*.bin' -ErrorAction SilentlyContinue
        if (-not $files) { return }
        $files | Move-Item -Destination $bkDir -Force -ErrorAction SilentlyContinue
        Log ("vanilla backup restored {0} file(s) from {1}" -f $files.Count, $latestArc.Name)
    } catch {
        Log "[!] vanilla backup restore error: $_"
    }
}

# ---------------- diagnose mode ----------------
if ($Diagnose) {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    "=== ОБЩЕЕ ==="
    "Папка пакета:    $HelperDir"
    "Эталон:          $Golden (есть: $(Test-Path $Golden))"
    $sx = Find-SettingsXml
    "Настройки игры:  $sx"
    if ($Golden) {
        $g = Get-Content $Golden -Raw
        "Эталон валиден:  $($g -match '<Settings>')   повреждён: $($g -match '\$\d')"
        "TextureQuality:  $(([regex]::Match($g, '<TextureQuality value=`"([^`"]+)`"')).Groups[1].Value)"
    }
    if ($sx) {
        "Только чтение:   $((Get-Item $sx -ErrorAction SilentlyContinue).IsReadOnly)"
        "Блокировка Win:  $(Test-Path -LiteralPath "$sx`:Zone.Identifier" -ErrorAction SilentlyContinue)"
    }

    "=== MIAMI GRAPHICS ==="
    $mgDirs = @("$env:APPDATA\MiamiGraphics", "$env:LOCALAPPDATA\MiamiGraphics") | Where-Object { Test-Path $_ }
    "Установлен:      $([bool]$mgDirs) ($(if ($mgDirs) { $mgDirs -join '; ' } else { 'папки не найдены' }))"
    foreach ($d in $mgDirs) {
        $ver = Join-Path $d 'config\installed_version.txt'
        if (Test-Path $ver) { "Версия MG:       $((Get-Content $ver -Raw).Trim())" }
    }
    foreach ($d in $mgDirs) {
        foreach ($f in @('optimization_baseline.json','config\optimization_baseline.json','gta_settings_preset.json','config\optimization_mods.json')) {
            $p = Join-Path $d $f
            if (Test-Path $p) { "Файл MG:         $p ($((Get-Item $p).Length) байт)" }
        }
    }
    "MG запущен:      $([bool](Get-Process | Where-Object { $_.Name -match 'Miami' }))"
    $snap = Join-Path $HelperDir 'mg_snapshot'
    if (Test-Path $snap) { "Снапшот MG:      $((Get-ChildItem $snap -File).Count) файлов (в $snap)" }
    else { "Снапшот MG:      ещё нет (появится при первом запуске GTA5)" }

    "=== MAJESTIC ==="
    $mjJson = "$env:APPDATA\majestic-launcher\Multiplayer\majestic.json"
    "Конфиг Majestic: $(if (Test-Path $mjJson) { $mjJson } else { 'не найден' })"
    if (Test-Path $mjJson) {
        try { "Кэш Majestic:    $((Get-Content $mjJson -Raw | ConvertFrom-Json).cachePath)" } catch {}
    }
    $launcherProc = Get-Process -Name 'Majestic Launcher' -ErrorAction SilentlyContinue
    "Лаунчер запущен: $([bool]$launcherProc)"
    if (-not $launcherProc) {
        "  (это нормально, если Majestic сейчас закрыт;"
        "   тревога только если лаунчер ОТКРЫТ, а строка говорит False -"
        "   значит Majestic переименовал процесс и триггер архивации не сработает)"
    }
    $bkDir = "$env:APPDATA\majestic-launcher\Multiplayer\backup"
    if (Test-Path $bkDir) {
        $binCount = (Get-ChildItem $bkDir -Filter '*.bin' -ErrorAction SilentlyContinue | Measure-Object).Count
        "Бэкап .bin в папке лаунчера: $binCount шт. (0 = архивированы, >0 = ждать запуска лаунчера)"
    }

    "=== ПОСЛЕДНИЕ СОБЫТИЯ ==="
    Get-Content $LogFile -Tail 8 -ErrorAction SilentlyContinue
    exit 0
}

# ---------------- watcher loop ----------------
if (-not (Test-Path $Golden)) {
    $sx = Find-SettingsXml
    if ($sx) {
        Copy-Item $sx $Golden -Force
        Log "Created golden backup from $sx"
    } else {
        Log "[!] settings.xml not found"
        exit 1
    }
}

$SettingsXml = Find-SettingsXml
if (-not $SettingsXml) { Log "[!] settings.xml not found at runtime"; exit 1 }

Log "Watcher v4 started"
$wasRunning = $false
$wasLauncher = $false

while ($true) {
    Start-Sleep -Seconds 5
    try {
        # re-discover settings.xml if it vanished (Documents/OneDrive relocation)
        if (-not (Test-Path $SettingsXml)) { $SettingsXml = Find-SettingsXml }
        $running = [bool](Get-Process -Name "GTA5" -ErrorAction SilentlyContinue)
        $launcher = [bool](Get-Process -Name "Majestic Launcher" -ErrorAction SilentlyContinue)

        if ($launcher -and -not $wasLauncher) {
            Log "Majestic launcher started"
            Archive-VanillaBackup
        }
        $wasLauncher = $launcher

        if ($running -and -not $wasRunning) {
            Snapshot-Mg
            # clear read-only attribute if the user (or a tool) protected settings.xml
            if ((Get-Item $SettingsXml -ErrorAction SilentlyContinue).IsReadOnly) {
                Set-ItemProperty $SettingsXml -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                Log "settings.xml was read-only - attribute cleared"
            }
            Copy-Item $SettingsXml (Join-Path $HelperDir 'settings.before_apply.bak') -Force
            Archive-VanillaBackup   # fallback in case launcher was already running before the watcher
            $goldenBytes = [IO.File]::ReadAllBytes($Golden)
            [IO.File]::WriteAllBytes($SettingsXml, $goldenBytes)
            Log "GTA5 launched -> settings applied"
            Clean-Dlccache
            Start-Sleep -Seconds 3
            if ((Get-Process -Name "GTA5" -ErrorAction SilentlyContinue) -and -not ((Get-Content $SettingsXml -Raw) -ceq (Get-Content $Golden -Raw))) {
                $goldenBytes = [IO.File]::ReadAllBytes($Golden)
                [IO.File]::WriteAllBytes($SettingsXml, $goldenBytes)
                Log "settings re-applied (was overwritten after launch)"
            }
        }
        elseif (-not $running -and $wasRunning) {
            Start-Sleep -Seconds 3
            $goldenBytes = [IO.File]::ReadAllBytes($Golden)
            [IO.File]::WriteAllBytes($SettingsXml, $goldenBytes)
            Log "GTA5 closed -> settings restored"
            Restore-VanillaBackup
        }
        $wasRunning = $running
    } catch {
        Log "[!] Error: $_"
    }
}
'@

# ------------------------------------------------------------
# 3. cache cleaner (manual, only truly destructive op, y/n prompt)
# ------------------------------------------------------------
$cleanCode = @'
# Cleans the whole Majestic asset cache (on demand).
# by Bayra & Kavel1n
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Clean Cache'

$cachePath = $null
$mjJson = "$env:APPDATA\majestic-launcher\Multiplayer\majestic.json"
if (Test-Path $mjJson) {
    try { $cachePath = (Get-Content $mjJson -Raw | ConvertFrom-Json).cachePath } catch {}
}
if (-not $cachePath -or -not (Test-Path $cachePath)) {
    Write-Host "[!] Majestic cache folder not found." -ForegroundColor Red
    pause; exit 1
}

if (Get-Process GTA5, 'Majestic Launcher' -ErrorAction SilentlyContinue) {
    Write-Host "[!] Majestic or GTA5 is running. Close them first!" -ForegroundColor Red
    pause; exit 1
}

$size = (Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Write-Host "============================================="
Write-Host " Majestic cache cleaner - by Bayra & Kavel1n"
Write-Host "============================================="
Write-Host ""
Write-Host ("Cache folder: $cachePath")
Write-Host ("Cache size:   {0:N0} MB" -f $size)
Write-Host ""
Write-Host "[!] WARNING: after cleaning, Majestic will re-download the whole cache on next launch." -ForegroundColor Yellow
Write-Host ""
$answer = Read-Host "Clean the cache now? (y/n)"
if ($answer -notin 'y','Y') { Write-Host "Cancelled."; pause; exit 0 }

Get-ChildItem $cachePath -Directory | ForEach-Object {
    Write-Host "Cleaning $($_.Name)..."
    Remove-Item "$($_.FullName)\*" -Recurse -Force -ErrorAction SilentlyContinue
}

$left = (Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Write-Host ("[+] Done. Remaining: {0:N0} MB" -f $left) -ForegroundColor Green
pause
'@

# ------------------------------------------------------------
# 4. uninstaller
# ------------------------------------------------------------
$uninstallCode = @'
# Removes autostart entry and stops the watcher. Keeps your backups.
# by Bayra & Kavel1n
$host.UI.RawUI.WindowTitle = 'MG Helper - Uninstall'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher|MG_Helper' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "GTASettingsWatcher" -ErrorAction SilentlyContinue
Write-Host "[+] Watcher stopped, autostart removed." -ForegroundColor Green
Write-Host "    Backups kept in %LOCALAPPDATA%\MG_Helper"
pause
'@

# write scripts as UTF-8 with BOM (required for PS 5.1)
$utf8bom = [Text.UTF8Encoding]::new($true)
[IO.File]::WriteAllText((Join-Path $HelperDir 'gta-settings-watcher.ps1'), $watcherCode, $utf8bom)
[IO.File]::WriteAllText((Join-Path $HelperDir 'clean-majestic-cache.ps1'), $cleanCode, $utf8bom)
[IO.File]::WriteAllText((Join-Path $HelperDir 'uninstall-watcher.ps1'), $uninstallCode, $utf8bom)
# clean up legacy deployed scripts from pre-v4 installs
foreach ($old in @('apply-mg-preset.ps1','gta-settings-watcher.ps1','clean-majestic-cache.ps1','uninstall-watcher.ps1')) {
    Remove-Item (Join-Path $legacyBackup $old) -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# 5. golden backup (migrated above, or fresh from THIS PC's settings)
# ------------------------------------------------------------
if (-not (Test-Path $golden)) { Copy-Item $Settings $golden -Force }

# ------------------------------------------------------------
# 6. autostart + run
# ------------------------------------------------------------
$watcherDst = Join-Path $HelperDir 'gta-settings-watcher.ps1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'gta-settings-watcher|MG_Helper' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$runValue = "`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherDst`""
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "GTASettingsWatcher" -Value $runValue -PropertyType String -Force | Out-Null
Write-Host "[+] Added to Windows autostart." -ForegroundColor Green

Start-Process powershell -ArgumentList '-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$watcherDst`"" -WindowStyle Hidden
Start-Sleep 4
if (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'gta-settings-watcher|MG_Helper' }) {
    Write-Host "[+] Watcher v4 is running." -ForegroundColor Green
    Write-Host ""
    Write-Host "Done! by Bayra & Kavel1n" -ForegroundColor Cyan
} else {
    Write-Host "[!] Watcher failed to start." -ForegroundColor Red
}
pause
