# package-release.ps1 - собирает, подписывает и упаковывает MG Helper, при -Upload
# публикует артефакты в GitHub Releases (так exe попадает на GitHub как asset релиза).
#
#   .\tools\package-release.ps1                 # собрать ZIP (+ Setup.exe, если есть Inno)
#   .\tools\package-release.ps1 -Upload          # + создать/обновить релиз и загрузить файлы
#   .\tools\package-release.ps1 -Upload -Prerelease
#
# Требования: подпись обязательна (tools\sign.ps1). Для публичного релиза без предупреждений
# SmartScreen нужен настоящий сертификат: -Pfx + MG_SIGN_PFX_PASSWORD (см. docs\SIGNING.md).
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Upload,
    [switch]$Prerelease,
    [switch]$SkipBuild,
    [string]$Repo = 'Minerkirad/MG-Helper-by-Bayra-and-Kavel1n',
    [string]$TagPrefix = 'v'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$release = Join-Path $repoRoot 'release'
New-Item -ItemType Directory -Force -Path $release | Out-Null

if (-not $Version) { $Version = ([IO.File]::ReadAllText((Join-Path $repoRoot 'version.json')) | ConvertFrom-Json).version }
$tag = "$TagPrefix$Version"
$stage = Join-Path $release 'stage'
Write-Host "[*] MG Helper $Version -> $release" -ForegroundColor Cyan

# ---------- 1. сборка ----------
if (-not $SkipBuild) {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tools\build-core.ps1') -OutputDir $stage -Force | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'build-core failed' }
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tools\build-ui.ps1') -OutputDir $stage -Force | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'build-ui failed' }

    # скрипты поддержки, ui и версия
    $deploy = @(
        'common.ps1', 'MgHelper.Core.ps1', 'gta-settings-watcher.ps1', 'MG-Helper.ps1', 'MG-Helper.bat',
        'diagnose.ps1', 'uninstall.ps1', 'repair.ps1', 'reset-settings.ps1', 'import-settings.ps1',
        'clean-majestic-cache.ps1', 'max-fps.ps1', 'cut-shadows.ps1', 'restore-mg-snapshot.ps1',
        'restore-golden-history.ps1', 'save-custom-profile.ps1', 'apply-custom-profile.ps1',
        'update-helper.ps1', 'install-gta-watcher.ps1', 'install-3.0.ps1', 'install-3.1.ps1',
        'CoreDecisions.cs', 'HelperPipe.cs', 'MGHelper.Watcher.cs', 'MGCore.cs',
        'MG-Helper-Host.cs', 'MG-Helper-Tray.cs', 'MGHelper.UI.cs', 'version.json'
    )
    foreach ($f in $deploy) {
        $src = Join-Path $repoRoot $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $stage $f) -Force }
    }
    Copy-Item (Join-Path $repoRoot 'ui') -Destination (Join-Path $stage 'ui') -Recurse -Force
    $certSrc = Join-Path $repoRoot 'assets\certs'
    if (Test-Path -LiteralPath $certSrc) { Copy-Item $certSrc -Destination (Join-Path $stage 'certs') -Recurse -Force }
    Remove-Item (Join-Path $stage 'ui\lib') -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- 2. подпись (обязательно) ----------
$exes = @(Get-ChildItem $stage -Filter '*.exe' -ErrorAction SilentlyContinue)
if ($exes.Count -eq 0) { throw "в $stage нет exe" }
& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tools\sign.ps1') -Auto -BuildDir $stage | Out-Null
$bad = @($exes | Where-Object { (Get-AuthenticodeSignature $_.FullName).Status -ne 'Valid' })
if ($bad.Count -gt 0) {
    throw ("подпись не подтверждена: " + (($bad | ForEach-Object { $_.Name }) -join ', ') + " - публиковать нельзя")
}
Write-Host ("[+] подписано: " + (($exes | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Green

# ---------- 3. ZIP ----------
$zip = Join-Path $release ("MG-Helper-$tag.zip")
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host "[+] ZIP: $([Math]::Round((Get-Item $zip).Length/1KB,1)) KB  SHA256=$zipHash" -ForegroundColor Green

# ---------- 4. Setup.exe (Inno Setup, если установлен) ----------
$setup = $null
$iscc = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($iscc) {
    Write-Host "[*] Inno Setup: $iscc" -ForegroundColor Cyan
    & $iscc "/DAppVersion=$Version" "/DStageDir=$stage" (Join-Path $repoRoot 'installer\mg-helper.iss') | Select-Object -Last 3
    $setup = Join-Path $release "MG-Helper-Setup-$Version.exe"
    if (Test-Path -LiteralPath $setup) {
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tools\sign.ps1') -Files $setup | Out-Null
        $setupHash = (Get-FileHash $setup -Algorithm SHA256).Hash
        Write-Host "[+] Setup: $([Math]::Round((Get-Item $setup).Length/1KB,1)) KB  SHA256=$setupHash" -ForegroundColor Green
    } else { Write-Host '[!] Inno не собрал Setup.exe' -ForegroundColor Yellow }
} else {
    Write-Host '[i] Inno Setup не установлен: Setup.exe пропущен, ZIP останется портативным' -ForegroundColor DarkGray
}

# ---------- 5. заметки с хэшами ----------
$notes = Join-Path $release "RELEASE-NOTES-$Version.md"
$zipHashLine = "MG-Helper-$tag.zip: ``$zipHash``"
$setupHashLine = if ($setup -and (Test-Path -LiteralPath $setup)) { "MG-Helper-Setup-$Version.exe: ``$((Get-FileHash $setup -Algorithm SHA256).Hash)``" } else { $null }
if (Test-Path -LiteralPath $notes) {
    $text = [IO.File]::ReadAllText($notes)
    $text = [regex]::Replace($text, 'MG-Helper-v[0-9A-Za-z.\-]+\.zip: `[A-Fa-f0-9]{64}`', $zipHashLine)
    if ($setupHashLine) {
        if ($text -match 'MG-Helper-Setup-[0-9A-Za-z.\-]+\.exe: `[A-Fa-f0-9]{64}`') {
            $text = [regex]::Replace($text, 'MG-Helper-Setup-[0-9A-Za-z.\-]+\.exe: `[A-Fa-f0-9]{64}`', $setupHashLine)
        } else {
            $text = $text.Replace($zipHashLine, $zipHashLine + "`r`n" + $setupHashLine)
        }
    }
    [IO.File]::WriteAllText($notes, $text, (New-Object System.Text.UTF8Encoding($false)))
} else {
    [IO.File]::WriteAllText($notes, "# MG Helper $Version`n`n$zipHashLine`n", (New-Object System.Text.UTF8Encoding($false)))
}
Write-Host "[+] заметки: $notes" -ForegroundColor Green

if (-not $Upload) {
    Write-Host '[*] без -Upload публикация не выполнялась'
    # тело релиза всегда соответствует локальным заметкам (хэши не расходятся с ассетами)
$bodyNow = if (Test-Path -LiteralPath $notes) { [IO.File]::ReadAllText($notes) } else { '' }
try {
    $patch = @{ body = $bodyNow } | ConvertTo-Json -Depth 3
    $null = Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/$Repo/releases/$($existing.id)" -Headers $hdr -Body $patch -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
    Write-Host '[+] обновляю тело релиза (хэши в тексте)' -ForegroundColor DarkGray
} catch { Write-Host "[!] тело релиза не обновлено: $($_.Exception.Message)" -ForegroundColor Yellow }
Write-Output $zip
    exit 0
}

# ---------- 6. публикация на GitHub ----------
$sig = @'
using System;
using System.Runtime.InteropServices;
public class CredPkg {
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool CredReadW(string target, int type, int flags, out IntPtr credential);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern void CredFree(IntPtr cred);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CREDENTIAL {
    public uint Flags; public uint Type; public IntPtr TargetName; public IntPtr Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize; public IntPtr CredentialBlob;
    public uint Persist; public uint AttributeCount; public IntPtr Attributes;
    public IntPtr TargetAlias; public IntPtr UserName;
  }
  public static byte[] GetBlob(string target) {
    IntPtr p; if (!CredReadW(target, 1, 0, out p)) return null;
    try {
      CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
      byte[] b = new byte[c.CredentialBlobSize];
      if (c.CredentialBlobSize > 0) Marshal.Copy(c.CredentialBlob, b, 0, (int)c.CredentialBlobSize);
      return b;
    } finally { CredFree(p); }
  }
}
'@
if (-not ('CredPkg' -as [type])) { Add-Type -TypeDefinition $sig -Language CSharp }
$token = [Text.Encoding]::UTF8.GetString([CredPkg]::GetBlob('gh:github.com:Minerkirad')).Trim()
if (-not $token) { throw 'нет токена GitHub в Credential Manager' }
$hdr = @{ Authorization = "token $token"; 'User-Agent' = 'MG-Helper' }

$body = ''
if (Test-Path -LiteralPath $notes) { $body = [IO.File]::ReadAllText($notes) }
$existing = $null
try { $existing = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/tags/$tag" -Headers $hdr -TimeoutSec 30 } catch { $existing = $null }
if (-not $existing) {
    $payload = @{ tag_name = $tag; name = "MG Helper $Version"; body = $body; draft = $false; prerelease = [bool]$Prerelease } | ConvertTo-Json -Depth 4
    $existing = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Repo/releases" -Headers $hdr -Body $payload -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
    Write-Host "[+] релиз создан: $($existing.html_url)" -ForegroundColor Green
} else {
    Write-Host "[i] релиз уже есть: $($existing.html_url)" -ForegroundColor DarkGray
}

$assets = @($zip)
if ($setup) { $assets += $setup }
foreach ($asset in $assets) {
    $name = [IO.Path]::GetFileName($asset)
    $old = @($existing.assets | Where-Object { $_.name -eq $name })
    foreach ($o in $old) {
        Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$Repo/releases/assets/$($o.id)" -Headers $hdr -TimeoutSec 30 | Out-Null
    }
    $bytes = [IO.File]::ReadAllBytes($asset)
    $res = Invoke-RestMethod -Method Post -Uri "https://uploads.github.com/repos/$Repo/releases/$($existing.id)/assets?name=$name" -Headers ($hdr + @{ 'Content-Type' = 'application/octet-stream' }) -Body $bytes -ContentType 'application/octet-stream' -TimeoutSec 600
    Write-Host ("[+] загружен asset: {0} ({1} b, state={2})" -f $res.name, $res.size, $res.state) -ForegroundColor Green
}
# тело релиза всегда соответствует локальным заметкам (хэши не расходятся с ассетами)
$bodyNow = if (Test-Path -LiteralPath $notes) { [IO.File]::ReadAllText($notes) } else { '' }
try {
    $patch = @{ body = $bodyNow } | ConvertTo-Json -Depth 3
    $null = Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/$Repo/releases/$($existing.id)" -Headers $hdr -Body $patch -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
    Write-Host '[+] обновляю тело релиза (хэши в тексте)' -ForegroundColor DarkGray
} catch { Write-Host "[!] тело релиза не обновлено: $($_.Exception.Message)" -ForegroundColor Yellow }
Write-Output $zip