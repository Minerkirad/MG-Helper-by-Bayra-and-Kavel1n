# fetch-webview2.ps1 - скачивает WebView2 SDK (pinned) в ui\lib и кладёт нужные DLL.
# В репозитории бинарники не хранятся (ui\lib в .gitignore): CI и локальная сборка
# вызывают этот скрипт, он идемпотентен и проверяет уже скачанное по версии.
#
#   .\tools\fetch-webview2.ps1            # скачать/проверить
#   .\tools\fetch-webview2.ps1 -Force     # перекачать
[CmdletBinding()]
param([string]$Version = '1.0.4370.26', [switch]$Force)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $repo 'ui\lib'
New-Item -ItemType Directory -Force -Path $lib | Out-Null
$stamp = Join-Path $lib '.version'
if (-not $Force -and (Test-Path -LiteralPath $stamp) -and ([IO.File]::ReadAllText($stamp).Trim() -eq $Version) -and
    (Test-Path -LiteralPath (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll')) -and
    (Test-Path -LiteralPath (Join-Path $lib 'WebView2Loader.dll'))) {
    Write-Host "[i] WebView2 SDK $Version уже на месте" -ForegroundColor DarkGray
    Write-Output $lib
    return
}

$work = Join-Path $env:TEMP ('wv2_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$nupkg = Join-Path $work 'wv2.nupkg'
$zip = Join-Path $work 'wv2.zip'
$url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$Version/microsoft.web.webview2.$Version.nupkg"
Write-Host "[*] скачиваю WebView2 SDK $Version" -ForegroundColor Cyan
Invoke-WebRequest $url -OutFile $nupkg -TimeoutSec 300
Copy-Item -LiteralPath $nupkg -Destination $zip -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$extract = Join-Path $work 'x'
[IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)

foreach ($name in 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll') {
    $src = Join-Path $extract "lib\net462\$name"
    if (-not (Test-Path -LiteralPath $src)) { throw "в пакете нет $name" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $lib $name) -Force
}
$loader = Join-Path $extract 'runtimes\win-x64\native\WebView2Loader.dll'
if (-not (Test-Path -LiteralPath $loader)) { throw 'в пакете нет WebView2Loader.dll (win-x64)' }
Copy-Item -LiteralPath $loader -Destination (Join-Path $lib 'WebView2Loader.dll') -Force
[IO.File]::WriteAllText($stamp, $Version, (New-Object System.Text.UTF8Encoding($false)))
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "[+] WebView2 SDK $Version готов: $lib" -ForegroundColor Green
Write-Output $lib