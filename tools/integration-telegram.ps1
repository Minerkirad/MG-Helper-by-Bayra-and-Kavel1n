# integration-telegram.ps1 - проверка отправки отчётов в Telegram БЕЗ интернета.
#
# Поднимает loopback TCP-«сервер», который принимает один HTTP-запрос и сохраняет его,
# наводит Send-TelegramDocument на него через -ApiBase и проверяет multipart:
# chat_id, имя файла и содержимое отчёта. Никакой сети и токенов не нужно.
#
#   .\tools\integration-telegram.ps1 [-Quiet]
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fails = New-Object System.Collections.Generic.List[string]
function Check([bool]$ok, [string]$what) {
    if ($ok) { if (-not $Quiet) { Write-Host "  PASS  $what" -ForegroundColor Green } }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $null = $script:fails.Add($what) }
}

$sandbox = Join-Path $env:TEMP ('mg_tg_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$report = Join-Path $sandbox 'report_test.txt'
$marker = 'MG-HELPER-TELEGRAM-REPORT-MARKER'
[IO.File]::WriteAllText($report, "MG Helper report`r`n$marker`r`n", [Text.UTF8Encoding]::new($false))
$capture = Join-Path $sandbox 'request.txt'

# свободный порт
$tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$tcp.Start()
$port = $tcp.LocalEndpoint.Port
$tcp.Stop()

$job = Start-Job -ArgumentList $port, $capture -ScriptBlock {
    param([int]$Port, [string]$Capture)
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    [IO.File]::WriteAllText($Capture + '.ready', 'ready', [Text.UTF8Encoding]::new($false))
    try {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $buffer = New-Object byte[] 65536
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        # дочитать тело по Content-Length, если пришло не всё
        $m = [regex]::Match($text, '(?i)Content-Length:\s*(\d+)')
        if ($m.Success) {
            $need = [int]$m.Groups[1].Value
            $headerEnd = $text.IndexOf("`r`n`r`n")
            $have = $read - ($headerEnd + 4)
            while ($have -lt $need) {
                $chunk = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $need - $have))
                if ($chunk -le 0) { break }
                $text += [Text.Encoding]::UTF8.GetString($buffer, 0, $chunk)
                $have += $chunk
            }
        }
        [IO.File]::WriteAllText($Capture, $text, [Text.UTF8Encoding]::new($false))
        $json = '{"ok":true}'
        $response = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($json.Length)`r`nConnection: close`r`n`r`n$json"
        $bytes = [Text.Encoding]::UTF8.GetBytes($response)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $client.Close()
    } finally { $listener.Stop() }
}

$oldToken = $env:MG_TG_TOKEN
$oldChat = $env:MG_TG_CHAT
$env:MG_TG_TOKEN = 'TEST-TOKEN'
$env:MG_TG_CHAT = '424242'
try {
    . (Join-Path $repo 'common.ps1')
    $readyFile = $capture + '.ready'
    $deadline = (Get-Date).AddSeconds(25)
    while (-not (Test-Path -LiteralPath $readyFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    Check (Test-Path -LiteralPath $readyFile) 'telegram: loopback listener is ready'
    $result = Send-TelegramDocument -Path $report -Caption 'MG Helper test' -ApiBase "http://127.0.0.1:$port"
    Check ([bool]$result.ok) "telegram: sendDocument returns ok (status $($result.status))"
    $wait = Wait-Job -Job $job -Timeout 20
    $captured = if (Test-Path -LiteralPath $capture) { [IO.File]::ReadAllText($capture) } else { '' }
    Check ($captured -match 'chat_id') 'telegram: the request carries chat_id'
    Check ($captured -match '424242') 'telegram: the configured chat id is sent'
    Check ($captured -match 'report_test\.txt') 'telegram: the report file name is in the multipart body'
    Check ($captured -match [regex]::Escape($marker)) 'telegram: the report content is uploaded'
    Check ($captured -match '/botTEST-TOKEN/sendDocument') 'telegram: the bot token goes to the API path'

    # без настроек отправка честно отказывает
    $env:MG_TG_TOKEN = $null
    $env:MG_TG_CHAT = $null
    $oldHelper = $script:HelperDir
    $script:HelperDir = $sandbox
    $noCfg = Send-TelegramDocument -Path $report -ApiBase "http://127.0.0.1:$port"
    $script:HelperDir = $oldHelper
    Check ((-not $noCfg.ok) -and ($noCfg.error -match 'не настроен')) 'telegram: without configuration it refuses instead of failing silently'
}
catch {
    Check $false ("telegram test crashed: " + $_.Exception.Message)
}
finally {
    if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    $env:MG_TG_TOKEN = $oldToken
    $env:MG_TG_CHAT = $oldChat
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails.Count -gt 0) {
    Write-Host ("TELEGRAM TEST FAILED: {0} check(s)" -f $fails.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'TELEGRAM TEST OK - report sending works against a loopback endpoint'
exit 0