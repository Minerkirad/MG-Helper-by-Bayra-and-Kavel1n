# MG Helper auto-update (opt-in) - by Bayra & Kavel1n
# ROADMAP 5.2: download the latest release ZIP, VERIFY its SHA256 against the
# hash published in the release notes, stage-extract, run the installer from
# staging. Never executes unverified content; keeps the previous install
# intact until the new installer succeeds.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'MG Helper - Update'
$ErrorActionPreference = 'Stop'

$repo = 'Minerkirad/MG-Helper-by-Bayra-and-Kavel1n'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$cur = '0.0'
try { $cur = (Get-Content "$env:LOCALAPPDATA\MG_Helper\version.json" -Raw | ConvertFrom-Json).version } catch {}

Write-Host "Текущая версия: v$cur"
$rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'MG-Helper' } -TimeoutSec 20
$latest = ($rel.tag_name -replace '^v', '')
Write-Host "Последняя версия: v$latest"
try {
    if ([version]$latest -le [version]$cur) { Write-Host '[+] У тебя уже последняя версия.' -ForegroundColor Green; exit 0 }
} catch { }

$asset = $rel.assets | Where-Object name -eq "MG-Helper-v$latest.zip" | Select-Object -First 1
if (-not $asset) { Write-Host '[!] ZIP-архив не найден в релизе.' -ForegroundColor Red; exit 1 }

# expected SHA256 from the release notes body
$expected = $null
if ($rel.body -match "MG-Helper-v$latest\.zip: ``([A-Fa-f0-9]{64})``") { $expected = $Matches[1] }
if (-not $expected) { Write-Host '[!] В описании релиза нет SHA256 - обновление отменено (безопасность).' -ForegroundColor Red; exit 1 }

$tmpZip = Join-Path $env:TEMP "MG-Helper-update-$latest.zip"
Invoke-WebRequest $asset.browser_download_url -OutFile $tmpZip -UserAgent 'MG-Helper' -TimeoutSec 600
$actual = (Get-FileHash -LiteralPath $tmpZip -Algorithm SHA256).Hash
if ($actual -ne $expected) {
    Write-Host "[!] SHA256 НЕ СОВПАЛ - архив повреждён или подменён. Обновление отменено." -ForegroundColor Red
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host '[+] SHA256 совпадает.' -ForegroundColor Green

$stage = Join-Path $env:TEMP ("mg_update_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
Expand-Archive -LiteralPath $tmpZip -DestinationPath $stage -Force
$newVer = ''
try { $newVer = (Get-Content (Join-Path $stage 'version.json') -Raw | ConvertFrom-Json).version } catch {}
if (-not $newVer) { Write-Host '[!] В архиве нет version.json - обновление отменено.' -ForegroundColor Red; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue; exit 1 }

Write-Host "[+] Архив проверен и распакован. Запускаю установку v$newVer..." -ForegroundColor Green
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stage 'install-gta-watcher.ps1')
$rc = $LASTEXITCODE
Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
if ($rc -ne 0) {
    Write-Host '[!] Установщик завершился с ошибкой - прежняя установка сохранена (staging).' -ForegroundColor Red
    exit 1
}
Write-Host "[+] Обновление до v$newVer завершено. Перезапусти меню." -ForegroundColor Green
