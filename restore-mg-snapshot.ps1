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

# only snapshots taken from THIS MG dir (root-qualified names)
$flat = ($mgDir -replace '[:\\/]', '_')
$files = Get-ChildItem $snapDir -Filter "$flat`__*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
if (-not $files) {
    Write-Host "[!] Снапшотов для текущей папки MG не найдено." -ForegroundColor Red
    Write-Host "    Доступные снапшоты:" -ForegroundColor Yellow
    Get-ChildItem $snapDir -File | ForEach-Object { Write-Host "      $($_.Name)" -ForegroundColor DarkGray }
    Write-Host "    Снапшоты с другого расположения MG на эту папку не переносятся."
    exit 1
}

# decode mapping: manifest.json is unambiguous (the legacy '__' flattening breaks
# if a folder/file name itself contains '__'); legacy decode is the fallback
$mapping = @{}
$manifestPath = Join-Path $snapDir 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $m.PSObject.Properties) {
            if ($p.Name.StartsWith("$flat`__")) { $mapping[$p.Name] = $p.Value }
        }
    } catch {}
}
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
$r = Read-Host "Восстановить настройки MG из снапшота? (да/нет)"
if ($r -notmatch '^(д|да|y|yes)$') { Write-Host "Отменено."; exit 0 }

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$preBackup = Join-Path $HelperDir "mg_before_restore_$stamp"
New-Item -ItemType Directory -Force -Path $preBackup | Out-Null

$restored = 0
foreach ($f in $files) {
    $rel = Get-SnapRelPath $f.Name
    if (-not $rel) {
        Write-Host "[!] $($f.Name): нет записи в manifest.json - пропущен" -ForegroundColor Yellow
        continue
    }
    $target = Join-Path $mgDir $rel
    $targetDir = Split-Path $target
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    if (Test-Path $target) { Copy-Item $target (Join-Path $preBackup $rel.Replace('\','__')) -Force }
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
