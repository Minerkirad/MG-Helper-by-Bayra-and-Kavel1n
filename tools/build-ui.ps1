# build-ui.ps1 - собирает MGHelper.exe (WebView2-хост, net48) тем же Add-Type/CodeDom,
# что host и watcher: никакого .NET SDK на машине разработчика не требуется.
#
#   .\tools\build-ui.ps1                    # в %TEMP%\mg_build
#   .\tools\build-ui.ps1 -OutputDir <путь>  # в каталог установки (install-3.1.ps1)
[CmdletBinding()]
param([string]$OutputDir, [switch]$Force)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $env:TEMP 'mg_build' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$lib = & (Join-Path $PSScriptRoot 'fetch-webview2.ps1')
$exe = Join-Path $OutputDir 'MGHelper.exe'
$source = Join-Path $repo 'MGHelper.UI.cs'
if (-not (Test-Path -LiteralPath $source)) { throw "нет исходника: $source" }
if (-not $Force -and (Test-Path -LiteralPath $exe) -and ((Get-Item $exe).LastWriteTimeUtc -ge (Get-Item $source).LastWriteTimeUtc)) {
    Write-Output $exe
    return
}
if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }

$refs = @(
    (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll'),
    (Join-Path $lib 'Microsoft.Web.WebView2.WinForms.dll'),
    'System.Windows.Forms',
    'System.Drawing',
    'System.Core',
    'System.Net.Http',
    'System.IO.Compression',
    'System.IO.Compression.FileSystem'
)
Add-Type -TypeDefinition ([IO.File]::ReadAllText($source)) -ReferencedAssemblies $refs -OutputAssembly $exe -OutputType WindowsApplication -ErrorAction Stop
# WebView2Loader.dll обязан лежать рядом с exe
Copy-Item -LiteralPath (Join-Path $lib 'WebView2Loader.dll') -Destination (Join-Path $OutputDir 'WebView2Loader.dll') -Force
Copy-Item -LiteralPath (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll') -Destination $OutputDir -Force
Copy-Item -LiteralPath (Join-Path $lib 'Microsoft.Web.WebView2.WinForms.dll') -Destination $OutputDir -Force
Write-Output $exe