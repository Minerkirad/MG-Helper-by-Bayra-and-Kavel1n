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
$mgDir = [IO.Path]::GetFullPath($mgDir).TrimEnd('\')

# ИСПРАВЛЕНО (analysis 3.9): flatten-префикс ТЕКУЩЕГО расположения MG. Писатель
# снапшотов (common.ps1 Snapshot-MgFiles) считает свой $rootFlat внутри себя, а
# читатель остался без переменной: фильтр "$flat__*.json" вырождался в "__*.json"
# и не совпадал ни с одним именем снапшота (имена вида
# C__Users_<user>_AppData_Local_MiamiGraphics__f14.json) -> "нет файлов" всегда.
$flat = $mgDir -replace '[:\\/]', '_'

# Расположения MG, файлы которых снапшот мог сохранить: писатель берёт и
# %APPDATA%\MiamiGraphics, и %LOCALAPPDATA%\MiamiGraphics. Восстанавливать можно
# в любой из них, но ТОЛЬКО в них - чужой путь из манифеста игнорируется.
$mgRoots = @()
foreach ($r in @($mgDir, (Join-Path $env:APPDATA 'MiamiGraphics'), (Join-Path $env:LOCALAPPDATA 'MiamiGraphics'))) {
    if (-not $r -or -not (Test-Path -LiteralPath $r -PathType Container)) { continue }
    $full = [IO.Path]::GetFullPath($r).TrimEnd('\')
    if ($mgRoots -notcontains $full) { $mgRoots += $full }
}
# flatten-префикс -> реальная папка. Нужен для снапшотов 2.6.0 и старее: roots
# в их манифесте нет, но имя файла начинается с flatten-корня источника.
$flatToRoot = @{}
foreach ($r in $mgRoots) { $flatToRoot[($r -replace '[:\\/]', '_')] = $r }
# Для старых снапшотов (2.6.0 и ранее) папка-источник восстанавливается из
# flatten-имени файла: иначе 20 из 21 файла этой машины легли бы в папку из
# config.json и затёрли бы её содержимое. Файл без адреса в имени - в $mgDir.

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
if ($gen) { $snapDir = $gen.FullName }

# "расположение" файла по его имени в снапшоте: 2.6.x пишет <flatten-корень>__fN.json
function Get-LocationLabel([string]$Name) {
    if ($Name -match '^(.*)__f\d+\.json$') { return $Matches[1] }
    return $Name
}

# roots (2.6.1): полный путь папки-источника каждого файла. Писатель держит его
# в отдельном roots.json поколения (common.ps1 Snapshot-MgFiles); ключ roots
# внутри manifest.json тоже принимаем - формат расширяемый.
function Add-RootsObject($Res, $Obj) {
    if ($null -eq $Obj) { return }
    if ($Obj -is [string]) { if ($Obj) { $Res.scalarRoot = [string]$Obj }; return }   # одна папка на все файлы
    try {
        foreach ($rp in $Obj.PSObject.Properties) {
            $val = [string]$rp.Value
            if (-not $val) { continue }
            $isFileKey = ($rp.Name -match '__f\d+\.json$') -or $Res.mapping.ContainsKey($rp.Name)
            if (-not $isFileKey) { $Res.prefixRoot[$rp.Name] = $val }            # ключ = flatten-корень
            elseif ($val -match '\.json$') { $Res.exact[$rp.Name] = $val }       # полный путь файла
            else { $Res.fileRoot[$rp.Name] = $val }                              # папка-источник файла
        }
    } catch {}
}

# manifest.json: относительный путь каждого файла. Читаем оба формата; roots опционален.
function Read-SnapManifest([string]$ManifestPath, [string]$RootsPath) {
    $res = @{ mapping = @{}; fileRoot = @{}; prefixRoot = @{}; exact = @{}; scalarRoot = $null; labels = @(); sourceRoots = @() }
    if (Test-Path -LiteralPath $ManifestPath) {
        try {
            $m = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
            # первый проход - относительные пути (нужны, чтобы опознать per-file ключи roots)
            foreach ($p in $m.PSObject.Properties) {
                if ($p.Name -ne 'roots') { $res.mapping[$p.Name] = [string]$p.Value }
            }
            foreach ($p in $m.PSObject.Properties) {
                if ($p.Name -eq 'roots') { Add-RootsObject $res $p.Value }
            }
        } catch {}
    }
    if ($RootsPath -and (Test-Path -LiteralPath $RootsPath)) {
        try { Add-RootsObject $res (Get-Content -LiteralPath $RootsPath -Raw -ErrorAction Stop | ConvertFrom-Json) } catch {}
    }
    # какие расположения вообще упомянуты в манифесте (для внятного сообщения):
    # из roots и из flatten-имён файлов
    $labels = @()
    foreach ($k in @($res.prefixRoot.Keys)) { $labels += $k }
    foreach ($k in @($res.fileRoot.Keys) + @($res.exact.Keys)) { $labels += (Get-LocationLabel $k) }
    foreach ($k in @($res.mapping.Keys)) { $labels += (Get-LocationLabel $k) }
    if ($res.scalarRoot) { $labels += "(roots = $($res.scalarRoot))" }
    $res.labels = @($labels | Where-Object { $_ } | Select-Object -Unique)
    # реальные папки-источники из roots (2.6.1): по ним видно, с какого ПК снят
    # снапшот, даже если ни одна из них не совпала с папками этого ПК
    $src = @()
    $src += @($res.prefixRoot.Values)
    $src += @($res.fileRoot.Values)
    foreach ($x in @($res.exact.Values)) { try { $src += (Split-Path ([string]$x) -Parent) } catch {} }
    if ($res.scalarRoot) { $src += [string]$res.scalarRoot }
    $res.sourceRoots = @($src | Where-Object { $_ } | Select-Object -Unique)
    return $res
}

# Куда положить файл снапшота: корень из roots (2.6.1), иначе из flatten-имени,
# иначе - текущая папка MG (старый формат без roots).
function Resolve-SnapTarget([string]$Name, $Manifest) {
    $src = ''
    $root = $null
    $rel = $null
    $full = $null
    $skip = $null
    if ($Manifest.mapping.ContainsKey($Name)) { $rel = [string]$Manifest.mapping[$Name] }
    if ($Manifest.exact.ContainsKey($Name)) {
        # roots отдал полный путь файла - он и есть цель
        $full = [string]$Manifest.exact[$Name]
        $root = Split-Path $full -Parent
        if (-not $rel) { $rel = Split-Path $full -Leaf }
        $src = 'roots: полный путь источника'
    }
    if (-not $root -and $Manifest.fileRoot.ContainsKey($Name)) { $root = [string]$Manifest.fileRoot[$Name]; $src = 'roots: папка-источник файла' }
    if (-not $root -and $Manifest.scalarRoot) { $root = [string]$Manifest.scalarRoot; $src = 'roots: общая папка источника' }
    if (-not $root) {
        foreach ($k in @($Manifest.prefixRoot.Keys)) {
            if ($Name -like "$k`__*") { $root = [string]$Manifest.prefixRoot[$k]; $src = 'roots: flatten-корень'; break }
        }
    }
    $pfxHit = $null
    if (-not $root) {
        # 2.6.0 и старее: корень виден только в flatten-имени файла
        foreach ($pfx in @($flatToRoot.Keys)) {
            if ($Name -like "$pfx`__*") { $pfxHit = $pfx; $root = $flatToRoot[$pfx]; $src = 'имя файла (flatten-корень)'; break }
        }
    }
    if (-not $rel) {
        if ($pfxHit) {
            $tail = $Name.Substring($pfxHit.Length + 2)
            # new-format name without a manifest entry: unusable, never decode to 'fN.json'
            if ($tail -match '^f\d+\.json$') { $skip = 'нет записи в манифесте (имя fN.json пути не даёт)' }
            else { $rel = $tail.Replace('__', '\') }   # legacy decode only
        }
        elseif ($Name -match '__f\d+\.json$') { $skip = 'нет записи в манифесте (имя fN.json пути не даёт)' }
        elseif ($Name -notmatch '^[A-Za-z]__|^__') { $rel = $Name }
        else { $skip = 'нераспознанное имя файла' }
    }
    if (-not $skip -and -not $root) {
        if ($Name -match '^[A-Za-z]__|^__') { $skip = 'другое расположение MG: снапшот снят не с папок этого ПК' }
        else { $root = $mgDir; $src = 'манифест: текущая папка MG' }
    }
    # REVIEW-#25: traversal guard - a broken/hostile manifest must not write
    # outside the MG folder
    if (-not $skip -and (-not $root -or -not $rel)) { $skip = 'пути не определены' }
    if (-not $skip -and ($rel -match '^\.\.|:')) { $skip = 'подозрительный путь в манифесте' }
    if (-not $skip) {
        try {
            $declared = [IO.Path]::GetFullPath($root).TrimEnd('\')
            if (-not $full) { $full = Join-Path $declared $rel }
            $full = [IO.Path]::GetFullPath($full)
            if (-not $full.StartsWith("$declared\", [StringComparison]::OrdinalIgnoreCase)) {
                $skip = 'путь вне корня источника'
            }
            else {
                # roots отдаёт папку-источник, но может отдать и полный путь файла
                # в подпапке (backup\, config\). Тогда корнем для бэкапа и проверки
                # считаем MG-папку этого ПК, внутри которой лежит файл.
                $owner = $null
                foreach ($mr in $mgRoots) {
                    if ($full.StartsWith("$mr\", [StringComparison]::OrdinalIgnoreCase)) {
                        if (-not $owner -or $mr.Length -gt $owner.Length) { $owner = $mr }
                    }
                }
                if (-not $owner) { $skip = "другое расположение MG: $(Split-Path $full -Parent)" }
                else { $root = $owner }
            }
        } catch { $skip = 'путь недопустим' }
    }
    return [pscustomobject]@{ root = $root; rel = $rel; full = $full; src = $src; skip = $skip }
}

$mani = Read-SnapManifest (Join-Path $snapDir 'manifest.json') (Join-Path $snapDir 'roots.json')

# manifest.json / roots.json - служебные файлы поколения, не данные MG
$allFiles = @(Get-ChildItem $snapDir -File -Filter '*.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('manifest.json', 'roots.json') } | Sort-Object LastWriteTime)
$files = $allFiles
if ($mani.mapping.Count -gt 0) {
    # manifest is the source of truth for this root: unmapped files are legacy
    # or stale leftovers - restoring them could overwrite fresh values (their
    # LastWriteTime equals the source json's mtime, so sort order is unreliable)
    $files = @($files | Where-Object { $mani.mapping.ContainsKey($_.Name) })
}

# Разбор всех файлов: что восстановим, куда именно и что пропустим (и почему)
$plan = @()
$skipped = @()
foreach ($f in $files) {
    $t = Resolve-SnapTarget $f.Name $mani
    if (-not $t.skip -and ($mgRoots -notcontains $t.root)) { $t.skip = "другое расположение MG: $($t.root)" }
    if ($t.skip) { $skipped += [pscustomobject]@{ name = $f.Name; why = $t.skip }; continue }
    $plan += [pscustomobject]@{ root = $t.root; rel = $t.rel; full = $t.full; src = $t.src; file = $f }
}

if ($plan.Count -eq 0) {
    Write-Host "[!] В снапшоте нет файлов для текущего расположения MG." -ForegroundColor Red
    Write-Host "    Текущая папка MG (config.json): $mgDir"
    Write-Host "    Ожидались папки MG этого ПК (папка -> flatten-префикс имени файла):"
    foreach ($r in $mgRoots) { Write-Host ("      {0}`n        -> {1}__*.json" -f $r, ($r -replace '[:\\/]', '_')) -ForegroundColor DarkGray }
    if ($mani.sourceRoots.Count -gt 0) {
        Write-Host "    В манифесте есть файлы из таких папок-источников:" -ForegroundColor Yellow
        foreach ($sr in $mani.sourceRoots) { Write-Host "      $sr" -ForegroundColor DarkGray }
    }
    elseif ($mani.labels.Count -gt 0) {
        Write-Host "    В манифесте есть файлы таких расположений:" -ForegroundColor Yellow
        foreach ($l in $mani.labels) {
            $cnt = @($allFiles | Where-Object { (Get-LocationLabel $_.Name) -eq $l }).Count
            Write-Host ("      {0}  ({1} файл(ов))" -f $l, $cnt) -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "    Манифест пуст или в нём нет ни одной записи - прочитать расположение источника нечем." -ForegroundColor Yellow
    }
    Write-Host "    Снапшоты с другого расположения MG на эту папку не переносятся."
    if ($skipped.Count -gt 0) {
        Write-Host "    Пропущено файлов: $($skipped.Count)" -ForegroundColor DarkGray
        foreach ($g in ($skipped | Group-Object -Property why)) { Write-Host ("      {0} - {1}" -f $g.Count, $g.Name) -ForegroundColor DarkGray }
    }
    exit 1
}

if ($gen) { Write-Host "Поколение:  $($gen.Name)" }
Write-Host "============================================="
Write-Host " Restore MG settings - by Bayra & Kavel1n"
Write-Host "============================================="
Write-Host ""
Write-Host "MG папка (config.json): $mgDir"
Write-Host "Файлов к восстановлению: $($plan.Count)   (flatten текущей папки: $flat)"
$curCount = @($plan | Where-Object { $_.root -eq $mgDir }).Count
if ($curCount -eq 0) {
    Write-Host "[i] В снапшоте нет файлов папки $mgDir (flatten: ${flat}__*.json) - будут восстановлены файлы других MG-папок этого ПК." -ForegroundColor Yellow
}
Write-Host ""
$byRoot = @{}
foreach ($it in $plan) {
    if (-not $byRoot.ContainsKey($it.root)) { $byRoot[$it.root] = New-Object System.Collections.ArrayList }
    [void]$byRoot[$it.root].Add($it)
}
foreach ($root in @($mgRoots | Where-Object { $byRoot.ContainsKey($_) })) {
    $items = @($byRoot[$root])
    $tag = if ($root -eq $mgDir) { 'текущая папка MG из config.json' } else { 'другой корень: MG брал файлы отсюда' }
    Write-Host ("  [{0}]  {1} файл(ов) - {2}" -f $root, $items.Count, $tag) -ForegroundColor Cyan
    foreach ($it in $items) { Write-Host ("      {0}   <- {1}" -f $it.rel, $it.src) -ForegroundColor DarkGray }
}
if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "[i] Пропущено файлов: $($skipped.Count)" -ForegroundColor Yellow
    foreach ($g in ($skipped | Group-Object -Property why)) { Write-Host ("      {0} - {1}" -f $g.Count, $g.Name) -ForegroundColor DarkGray }
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
$failed = 0
$bakIdx = 0
foreach ($it in $plan) {
    $rootFull = $it.root
    $target = $it.full
    $tFull = $target
    try { $tFull = [IO.Path]::GetFullPath($target) } catch {}
    # REVIEW-#25: traversal guard - the target must stay inside its own MG root
    if (-not $tFull.StartsWith("$rootFull\", [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "[!] $($it.rel): путь вне корня MG - пропущен" -ForegroundColor Yellow
        $failed++
        continue
    }
    $targetDir = Split-Path $tFull
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    if (Test-Path -LiteralPath $tFull) {
        # REVIEW-#25: unique per-file backup name (the '__' flattening collided);
        # бэкап раскладывается по подпапкам корней, чтобы было видно, что откуда.
        # Без успешного бэкапа файл НЕ перезаписываем: иначе восстановление
        # может потерять текущие настройки (promise "ничего не теряется").
        $bakSub = Join-Path $preBackup ($rootFull -replace '[:\\/]', '_')
        try {
            if (-not (Test-Path -LiteralPath $bakSub)) { New-Item -ItemType Directory -Force -Path $bakSub -ErrorAction Stop | Out-Null }
            $bakIdx++
            Copy-Item -LiteralPath $tFull (Join-Path $bakSub ("bak{0:D3}.json" -f $bakIdx)) -Force -ErrorAction Stop
        } catch {
            $failed++
            Write-Host "[!] $($it.rel): не удалось сохранить бэкап - файл не перезаписан ($($_.Exception.Message))" -ForegroundColor Yellow
            continue
        }
    }
    try {
        Copy-Item -LiteralPath $it.file.FullName -Destination $tFull -Force -ErrorAction Stop
        $restored++
    } catch {
        $failed++
        Write-Host "[!] $($it.rel): не удалось восстановить ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "[+] Восстановлено файлов: $restored" -ForegroundColor Green
if ($bakIdx -gt 0) { Write-Host "[+] Прежние файлы MG: $preBackup" -ForegroundColor DarkGray }
if ($failed -gt 0) { Write-Host "[!] Не удалось восстановить файлов: $failed" -ForegroundColor Yellow }
Write-Host ""
Write-Host "Перезапусти лаунчер Miami Graphics, чтобы он подхватил восстановленные настройки." -ForegroundColor Cyan
if ($restored -eq 0) { exit 1 }
exit 0
