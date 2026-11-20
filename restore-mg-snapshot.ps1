# MG Helper - restore MG settings from snapshot - by Bayra & Kavel1n
# Restores Miami Graphics json files from the newest snapshot taken by the watcher.
# Existing MG files are backed up before restore (nothing is lost).
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Restore MG Snapshot'

$HelperDir = Join-Path $env:LOCALAPPDATA 'MG_Helper'
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg = Resolve-MgPaths -NoSave
$mgDir = $cfg.miamiGraphicsDir
if (-not $mgDir -or -not (Test-Path -LiteralPath $mgDir)) {
    Write-Host "[!] Miami Graphics не найден на этом ПК - восстанавливать некуда." -ForegroundColor Red
    exit 1
}

$snapDir = Join-Path $HelperDir 'mg_snapshot'
if (-not (Test-Path $snapDir)) {
    Write-Host "[!] Снапшотов ещё нет - они появятся после первого запуска GTA5." -ForegroundColor Red
    exit 1
}

# ROADMAP 2.4: snapshot GENERATIONS (newest kept = 5). New layout: each
# generation is a folder with its own manifest.json. Legacy flat layout is
# still supported as a fallback.
$snapRoot = $snapDir
$gen = $null
$gens = @(Get-ChildItem $snapRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
    Sort-Object Name -Descending)
if ($gens.Count -gt 0) {
    Write-Host "Доступные поколения MG-снапшотов (новые сверху):"
    for ($i = 0; $i -lt $gens.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $gens[$i].Name) -ForegroundColor $(if ($i -eq 0) { 'Green' } else { 'DarkGray' })
    }
    $pick = Read-Host "Выбери поколение (Enter = новейшее)"
    $pickIdx = 0
    if ($pick -match '^\d+$' -and ([int]$pick -ge 1) -and ([int]$pick -le $gens.Count)) { $pickIdx = [int]$pick - 1 }
    $gen = $gens[$pickIdx]
}

if ($gen) {
    $snapDir = $gen.FullName
    $files = Get-ChildItem $snapDir -Filter "$flat`__*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
    if (-not $files) {
        Write-Host "[!] В выбранном поколении нет файлов для текущей папки MG." -ForegroundColor Red
        exit 1
    }
    $mapping = @{}
    try {
        $m = Get-Content -LiteralPath (Join-Path $snapDir 'manifest.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $m.PSObject.Properties) {
            if ($p.Name.StartsWith("$flat`__")) { $mapping[$p.Name] = $p.Value }
        }
    } catch {}
}
else {
    # legacy flat layout (old versions)
    $files = Get-ChildItem $snapRoot -Filter "$flat`__*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
    if (-not $files) {
        Write-Host "[!] Снапшотов для текущей папки MG не найдено." -ForegroundColor Red
        Write-Host "    Доступные снапшоты:" -ForegroundColor Yellow
        Get-ChildItem $snapRoot -File | ForEach-Object { Write-Host "      $($_.Name)" -ForegroundColor DarkGray }
        Write-Host "    Снапшоты с другого расположения MG на эту папку не переносятся."
        exit 1
    }
    $mapping = @{}
    $manifestPath = Join-Path $snapRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $m = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in $m.PSObject.Properties) {
                if ($p.Name.StartsWith("$flat`__")) { $mapping[$p.Name] = $p.Value }
            }
        } catch {}
    }
}

# decode mapping: manifest.json is unambiguous (the legacy '__' flattening breaks
# if a folder/file name itself contains '__'); legacy decode is the fallback
function Get-SnapRelPath([string]$SnapName) {
    if ($mapping.ContainsKey($SnapName)) { return $mapping[$SnapName] }
    $tail = $SnapName.Substring("$flat`__".Length)
    # new-format name without a manifest entry: unusable, never decode to 'fN.json'
    if ($tail -match '^f\d+\.json$') { return $null }
    return $tail.Replace('__', '\')   # legacy decode only
}

if ($mapping.Count -gt 0) {
    # manifest is the source of truth for this root: unmapped files are legacy
    # or stale leftovers - restoring them could overwrite fresh values (their
    # LastWriteTime equals the source json's mtime, so sort order is unreliable)
    $files = @($files | Where-Object { $mapping.ContainsKey($_.Name) })
}
if ($gen) { Write-Host "Поколение:  $($gen.Name)" }

Write-Host "============================================="
Write-Host " Restore MG settings - by Bayra & Kavel1n"
Write-Host "============================================="
Write-Host ""
Write-Host "MG папка:   $mgDir"
Write-Host "Файлов в снапшоте: $($files.Count)"
Write-Host ""
foreach ($f in $files) {
    $rel = Get-SnapRelPath $f.Name
    Write-Host "  $rel"
}
Write-Host ""
Write-Host "[i] Текущие файлы MG будут сохранены в бэкап перед восстановлением." -ForegroundColor Yellow
# REVIEW-#25: restoring under a running MG may be overwritten by it on exit
if (Get-Command Find-MatchingProcess -ErrorAction SilentlyContinue) {
    if ([bool](Find-MatchingProcess -Patterns $cfg.mgProcesses)) {
        Write-Host "[!] Miami Graphics ЗАПУЩЕН - закрой его перед восстановлением!" -ForegroundColor Red
        exit 1
    }
}
$r = Read-Host "Восстановить настройки MG из снапшота? (да/нет)"
if ($r -notmatch '^(д|да|y|yes)$') { Write-Host "Отменено."; exit 0 }

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$preBackup = Join-Path $HelperDir "mg_before_restore_$stamp"
New-Item -ItemType Directory -Force -Path $preBackup | Out-Null

$restored = 0
$bakIdx = 0
foreach ($f in $files) {
    $rel = Get-SnapRelPath $f.Name
    if (-not $rel) {
        Write-Host "[!] $($f.Name): нет записи в manifest.json - пропущен" -ForegroundColor Yellow
        continue
    }
    # REVIEW-#25: traversal guard - a broken/hostile manifest must not write
    # outside the MG folder
    if ($rel -match '^\.\.|:' -or ([IO.Path]::GetFullPath((Join-Path $mgDir $rel)) -notlike "$mgDir*")) {
        Write-Host "[!] $($f.Name): подозрительный путь в манифесте - пропущен" -ForegroundColor Yellow
        continue
    }
    $target = Join-Path $mgDir $rel
    $targetDir = Split-Path $target
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    if (Test-Path $target) {
        # REVIEW-#25: unique per-file backup name (the '__' flattening collided)
        $bakIdx++
        Copy-Item $target (Join-Path $preBackup ("bak{0:D3}.json" -f $bakIdx)) -Force
    }
    try {
        Copy-Item $f.FullName $target -Force -ErrorAction Stop
        $restored++
    } catch {
        Write-Host "[!] $($f.Name): не удалось восстановить ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "[+] Восстановлено файлов: $restored" -ForegroundColor Green
Write-Host "[+] Прежние файлы MG: $preBackup" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Перезапусти лаунчер Miami Graphics, чтобы он подхватил восстановленные настройки." -ForegroundColor Cyan
