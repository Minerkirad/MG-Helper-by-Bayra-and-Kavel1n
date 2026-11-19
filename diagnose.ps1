# Locates the deployed watcher and runs its -Diagnose mode.
# Used as source for 5-diagnose.bat (EncodedCommand).
# by Bayra & Kavel1n
$host.UI.RawUI.WindowTitle = 'MG Helper Diagnose - by Bayra & Kavel1n'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$roots = @(
    "$env:LOCALAPPDATA\MG_Helper",
    "$env:USERPROFILE\Documents\Rockstar Games\GTA V\_settings_backup",
    "$env:USERPROFILE\OneDrive\Documents\Rockstar Games\GTA V\_settings_backup"
)
foreach ($one in (Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
    $roots += (Join-Path $one.FullName 'Documents\Rockstar Games\GTA V\_settings_backup')
}

$found = $null
foreach ($r in ($roots | Select-Object -Unique)) {
    $wp = Join-Path $r 'gta-settings-watcher.ps1'
    if (Test-Path $wp) { $found = $wp; break }
}

if (-not $found) {
    Write-Host "[!] Watcher not found on this PC." -ForegroundColor Red
    Write-Host "    Run MG-Helper.bat -> [1] first (it installs the watcher)."
    Write-Host ""
    Write-Host "Searched:"
    $roots | ForEach-Object { Write-Host "    $_" }
    exit 1
}

Write-Host "[i] Watcher found: $found"
Write-Host "=================================================="

# capture diagnose output: shown on screen AND saved to a report bundle ready to send
$watcherDir = Split-Path $found
$rep = & powershell -NoProfile -ExecutionPolicy Bypass -File $found -Diagnose 2>&1
$rep | ForEach-Object { $_.ToString() } | Write-Host
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$header = "MG Helper diagnostic report - $stamp - by Bayra & Kavel1n"
$header + "`r`n" + (($rep | ForEach-Object { $_.ToString() }) -join "`r`n") |
    Out-File (Join-Path $watcherDir "report_$stamp.txt") -Encoding UTF8

# enrich the report: config, longer log, snapshot list, archive listing, versions
$extra = @()
$diskLines = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
    ForEach-Object { "Диск $($_.DeviceID) свободно: $([int]($_.FreeSpace / 1GB)) ГБ" })
if ($diskLines.Count -eq 0) { $diskLines = @("Диск C свободно: $([int]((Get-PSDrive C -ErrorAction SilentlyContinue).Free / 1GB)) ГБ") }
$extra += ""
$extra += "=== ОКРУЖЕНИЕ ==="
$extra += "OS:     $([Environment]::OSVersion.VersionString)"
$extra += "PS:     $($PSVersionTable.PSVersion)"
$extra += $diskLines
$extra += ""
$extra += "=== CONFIG.JSON (ключи и версии; пути маскируются) ==="
$extra += (Get-Content (Join-Path $watcherDir 'config.json') -Raw -ErrorAction SilentlyContinue)
$extra += ""
$extra += "=== WATCHER.LOG (последние 40 строк) ==="
$extra += (Get-Content (Join-Path $watcherDir 'watcher.log') -Tail 40 -ErrorAction SilentlyContinue)
$extra += ""
$extra += "=== MG SNAPSHOT ==="
$extra += (Get-ChildItem (Join-Path $watcherDir 'mg_snapshot') -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($($_.Length) байт)" })
$extra += ""
$extra += "=== VANILLA BACKUP ARCHIVE ==="
$extra += (Get-ChildItem (Join-Path $watcherDir 'vanilla_backup_archive') -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($([int]($_.Length / 1MB)) МБ)" })
$extra | Add-Content (Join-Path $watcherDir "report_$stamp.txt") -Encoding UTF8

# MG-CR-011: the report goes to strangers - mask the user's identity by default.
# Full paths are opt-in with explicit confirmation. Applied to the WHOLE file
# (including the watcher -Diagnose header) by post-processing.
$mask = $true
Write-Host ""
$fullAnswer = Read-Host "Включить в отчёт ПОЛНЫЕ пути (содержат имя пользователя)? (да/нет)"
if ($fullAnswer -match '^(д|да|y|yes)$') { $mask = $false }
$reportPath = Join-Path $watcherDir "report_$stamp.txt"
if ($mask) {
    $rp = (Resolve-Path -LiteralPath $reportPath -ErrorAction SilentlyContinue).Path
    if ($rp) {
        $content = Get-Content -LiteralPath $rp -Raw -ErrorAction SilentlyContinue
        $content = $content -replace [regex]::Escape($env:USERPROFILE), 'C:\Users\<USER>'
        $content = $content -replace [regex]::Escape($env:USERDOMAIN + '\' + $env:USERNAME), '<USER>'
        $content = $content -replace [regex]::Escape($env:USERNAME), '<USER>'
        [IO.File]::WriteAllText($rp, $content, [Text.UTF8Encoding]::new($true))
    }
}

Write-Host "=================================================="
Write-Host "[+] Report saved: report_$stamp.txt (in the watcher folder)" -ForegroundColor Green
Write-Host "    Send that FILE (not a screenshot) to Bayra / Kavel1n." -ForegroundColor Green
if ($mask) { Write-Host "[i] Персональные пути замаскированы (C:\Users\<USER>)." -ForegroundColor DarkGray }
else { Write-Host "[i] ВНИМАНИЕ: отчёт содержит ПОЛНЫЕ пути с именем пользователя." -ForegroundColor Yellow }
# open Explorer with the report file selected
Start-Process explorer.exe "/select,`"$watcherDir\report_$stamp.txt`""
