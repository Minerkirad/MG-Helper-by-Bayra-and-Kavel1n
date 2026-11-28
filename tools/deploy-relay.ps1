# deploy-relay.ps1 - разворачивает воркер-релей отчётов в Cloudflare через REST API.
#
# Нужен только API-токен Cloudflare с правами Workers Scripts:Edit.
# Токен берётся из переменной окружения MG_CF_TOKEN (в файлы и репозиторий не пишется).
#
#   $env:MG_CF_TOKEN = '<токен>'
#   .\tools\deploy-relay.ps1 -BotToken '<токен бота>'
#   .\tools\deploy-relay.ps1 -BotToken '...' -ChatId '123456'   # если chat_id уже известен
#
# Что делает:
#   1) узнаёт account_id по токену
#   2) заливает relay/worker.js как модульный воркер mg-helper-reports
#   3) включает поддомен *.workers.dev (если ещё не включён)
#   4) кладёт секреты TG_TOKEN, MG_KEY
#   5) если chat_id не передан - вызывает /discover и печатает найденные chat_id
#   6) проверяет /health и, при известном chat_id, шлёт тестовый отчёт
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BotToken,
    [string]$ChatId,
    [string]$WorkerName = 'mg-helper-reports',
    [string]$KeyPath = '/mg-helper-reports/report'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$api = 'https://api.cloudflare.com/client/v4'
$token = $env:MG_CF_TOKEN
if (-not $token) { throw 'нет MG_CF_TOKEN: создайте токен Cloudflare (Workers Scripts:Edit) и задайте переменную окружения' }
$hdr = @{ Authorization = "Bearer $token" }

# --- 1. account_id ---
$accounts = Invoke-RestMethod "$api/accounts" -Headers $hdr -TimeoutSec 30
if (-not $accounts.success) { throw ('Cloudflare API: ' + ($accounts.errors | ConvertTo-Json -Compress)) }
$accountId = $accounts.result[0].id
Write-Host "[i] аккаунт: $($accounts.result[0].name) ($accountId)"
# --- 2. заливка воркера (multipart/form-data, ES-модуль) ---
$workerSrc = Get-Content -LiteralPath (Join-Path $repo 'relay\worker.js') -Raw
$meta = @{ main_module = 'worker.js'; compatibility_date = '2024-11-01' } | ConvertTo-Json -Compress
$tmpMeta = Join-Path $env:TEMP ('cf_meta_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
$tmpCode = Join-Path $env:TEMP ('cf_worker_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.mjs')
[IO.File]::WriteAllText($tmpMeta, $meta, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($tmpCode, $workerSrc, [Text.UTF8Encoding]::new($false))
try {
    $up = & curl.exe -s -X PUT "$api/accounts/$accountId/workers/scripts/$WorkerName" `
        -H "Authorization: Bearer $token" `
        -F "metadata=@$tmpMeta;type=application/json" `
        -F "worker.js=@$tmpCode;type=application/javascript+module" 2>&1
    $upJson = $up | ConvertFrom-Json
    if (-not $upJson.success) { throw ('заливка не удалась: ' + ($upJson.errors | ConvertTo-Json -Compress)) }
    Write-Host "[+] воркер залит: $WorkerName" Green
} finally {
    Remove-Item $tmpMeta, $tmpCode -Force -ErrorAction SilentlyContinue
}

# --- 3. поддомен workers.dev ---
$sub = Invoke-RestMethod "$api/accounts/$accountId/workers/subdomain" -Headers $hdr -TimeoutSec 30
$subdomain = $sub.result.subdomain
if (-not $subdomain) {
    $random = 'mg' + ([guid]::NewGuid().ToString('N').Substring(0, 10))
    $created = Invoke-RestMethod -Method Put "$api/accounts/$accountId/workers/subdomain" -Headers $hdr -Body (@{ subdomain = $random } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 30
    $subdomain = $created.result.subdomain
}
$workerUrl = "https://$WorkerName.$subdomain.workers.dev"
Write-Host "[i] адрес воркера: $workerUrl" Cyan
# --- 4. секреты ---
$mgKey = [guid]::NewGuid().ToString('N')
function Set-Secret([string]$name, [string]$value) {
    $body = @{ name = $name; text = $value; type = 'secret_text' } | ConvertTo-Json -Compress
    $r = & curl.exe -s -X PUT "$api/accounts/$accountId/workers/scripts/$WorkerName/secrets" `
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d $body 2>&1
    $rj = $r | ConvertFrom-Json
    if (-not $rj.success) { throw ("секрет $name не записан: " + ($rj.errors | ConvertTo-Json -Compress)) }
    Write-Host "[+] секрет $name записан" Green
}
Set-Secret 'TG_TOKEN' $BotToken
Set-Secret 'MG_KEY' $mgKey
if ($ChatId) { Set-Secret 'TG_CHAT' $ChatId }

# --- 5. chat_id через /discover ---
if (-not $ChatId) {
    Start-Sleep -Seconds 3
    try {
        $d = Invoke-RestMethod "$workerUrl/discover" -Headers @{ 'X-MG-Key' = $mgKey } -TimeoutSec 30
        if ($d.ok -and $d.chats.Count -gt 0) {
            Write-Host '[i] найдены чаты, которые писали боту:' Cyan
            $d.chats | ForEach-Object { Write-Host ("    id={0}  type={1}  {2}" -f $_.id, $_.type, $_.name) }
            $ChatId = [string]$d.chats[0].id
            Set-Secret 'TG_CHAT' $ChatId
        } else {
            Write-Host '[!] боту ещё не писали: отправьте ему /start, затем повторите -ChatId не задан' Yellow
        }
    } catch { Write-Host ("[!] /discover: " + $_.Exception.Message) -ForegroundColor Yellow }
}

# --- 6. проверка ---
Start-Sleep -Seconds 2
try {
    $h = Invoke-RestMethod "$workerUrl/health" -TimeoutSec 30
    Write-Host ("[+] /health: configured={0} chatSet={1}" -f $h.configured, $h.chatSet) Green
} catch { Write-Host ("[!] /health: " + $_.Exception.Message) -ForegroundColor Yellow }

if ($ChatId) {
    $live = Join-Path $env:LOCALAPPDATA 'MG_Helper'
    $rep = Get-ChildItem $live -Filter 'report_*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($rep) {
        $body = @{ 'chat_id' = $ChatId } # заглушка, используется multipart ниже
        $mp = & curl.exe -s -X POST "$workerUrl/report" -F "version=deploy-test" -F "caption=MG Helper relay test" -F "document=@$($rep.FullName);type=text/plain" 2>&1
        $mpj = $mp | ConvertFrom-Json
        if ($mpj.ok) { Write-Host '[+] тестовый отчёт отправлен в Telegram' -ForegroundColor Green }
        else { Write-Host ('[!] отправка: ' + ($mp | Out-String).Trim()) -ForegroundColor Yellow }
    }
}

Write-Host ''
Write-Host "URL для config.json -> reportUrl: $workerUrl" Cyan
Write-Host "Ключ (служебный, в клиенте не нужен): $mgKey" DarkGray
exit 0