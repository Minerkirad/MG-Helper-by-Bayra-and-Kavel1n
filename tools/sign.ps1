# sign.ps1 - подпись артефактов MG Helper (обязательный шаг релиза).
#
# Два режима сертификата:
#   1) настоящий код-сертификат: -Pfx <файл>, пароль в env MG_SIGN_PFX_PASSWORD
#      (в CI — секрет репозитория; локально — переменная окружения). Так подписываются
#      публичные релизы.
#   2) self-signed для разработки/тестов: -CreateSelfSigned создаёт сертификат
#      Code Signing в Cert:\CurrentUser\My, экспортирует .cer в assets\certs и, с
#      -TrustLocal, добавляет его в доверенные корни текущего пользователя, чтобы
#      подпись была Valid на этой машине.
#
#   .\tools\sign.ps1 -CreateSelfSigned -TrustLocal          # один раз на машине
#   .\tools\sign.ps1 -Files <exe1>,<exe2>                   # подписать
#   .\tools\sign.ps1 -Auto -BuildDir %TEMP%\mg_build        # подписать всё в каталоге
#   .\tools\sign.ps1 -Pfx C:\secret\mg.pfx -Files ...       # настоящий сертификат
[CmdletBinding()]
param(
    [string[]]$Files,
    [switch]$Auto,
    [string]$BuildDir,
    [switch]$CreateSelfSigned,
    [switch]$TrustLocal,
    [string]$Pfx,
    [string]$PfxPasswordEnv = 'MG_SIGN_PFX_PASSWORD',
    [string]$Subject = 'CN=MG Helper by Bayra & Kavel1n, O=MG Helper, C=RU',
    [string]$Timestamp = 'http://timestamp.digicert.com',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$certDir = Join-Path $repo 'assets\certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

function Say([string]$text) { if (-not $Quiet) { Write-Host $text } }

function Get-SigningCertificate {
    if ($Pfx) {
        if (-not (Test-Path -LiteralPath $Pfx)) { throw "PFX не найден: $Pfx" }
        $password = [Environment]::GetEnvironmentVariable($PfxPasswordEnv)
        if (-not $password) { throw "нет пароля в переменной $PfxPasswordEnv" }
        $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
        return (Get-PfxCertificate -FilePath $Pfx)
    }
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like "*MG Helper*" } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($cert) { return $cert }
    return $null
}

if ($CreateSelfSigned) {
    $existing = Get-SigningCertificate
    if ($existing -and -not $Pfx) {
        Say "[i] сертификат уже есть: $($existing.Thumbprint)"
        $cert = $existing
    } else {
        $params = @{
            Type              = 'CodeSigningCert'
            Subject           = $Subject
            KeyUsage          = 'DigitalSignature'
            KeyExportPolicy   = 'Exportable'
            CertStoreLocation = 'Cert:\CurrentUser\My'
            NotAfter          = (Get-Date).AddYears(3)
            TextExtension     = @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
        }
        $cert = New-SelfSignedCertificate @params
        Say "[+] создан self-signed код-сертификат: $($cert.Thumbprint)"
    }
    $cerPath = Join-Path $certDir 'mghelper-selfsigned.cer'
    Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null
    Say "[+] открытый сертификат: $cerPath"
    if ($TrustLocal) {
        try {
            $already = Get-ChildItem Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
            if ($already) {
                Say "[i] сертификат уже в доверенных корнях текущего пользователя"
            } else {
                Import-Certificate -FilePath $cerPath -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
                Say "[+] сертификат добавлен в доверенные корни текущего пользователя"
            }
        } catch { Say "[!] не удалось добавить в доверенные корни: $($_.Exception.Message)" }
    }
    if (-not $Files -and -not $Auto) { return }
}

if ($Auto) {
    if (-not $BuildDir) { $BuildDir = Join-Path $env:TEMP 'mg_build' }
    $Files = @(Get-ChildItem $BuildDir -File -Filter '*.exe' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    if (-not $Files -or $Files.Count -eq 0) { throw "в $BuildDir нет exe для подписи" }
}
if (-not $Files -or $Files.Count -eq 0) { throw 'нечего подписывать: передай -Files или -Auto -BuildDir' }

$cert = Get-SigningCertificate
if (-not $cert) { throw 'нет сертификата: создай self-signed (-CreateSelfSigned) или передай -Pfx' }
Say "[i] подпись сертификатом: $($cert.Subject) ($($cert.Thumbprint))"

$failed = 0
foreach ($file in $Files) {
    if (-not (Test-Path -LiteralPath $file)) { Write-Host "[!] нет файла: $file" -ForegroundColor Yellow; $failed++; continue }
    try {
        try {
            $result = Set-AuthenticodeSignature -FilePath $file -Certificate $cert -TimestampServer $Timestamp -HashAlgorithm SHA256
        } catch {
            # офлайн-сборка: подписываем без метки времени, но честно об этом говорим
            Write-Host "[!] timestamp недоступен ($($_.Exception.Message)) - подпись без метки времени" -ForegroundColor Yellow
            $result = Set-AuthenticodeSignature -FilePath $file -Certificate $cert -HashAlgorithm SHA256
        }
        $check = Get-AuthenticodeSignature -FilePath $file
        $status = $check.Status
        if ($status -in @('Valid', 'UnknownError', 'NotTrusted')) {
            Say ("[+] {0}: {1}" -f (Split-Path $file -Leaf), $status)
        } else {
            Write-Host ("[!] {0}: подпись не подтверждена - {1} {2}" -f (Split-Path $file -Leaf), $status, $check.StatusMessage) -ForegroundColor Yellow
            $failed++
        }
    } catch {
        Write-Host ("[!] {0}: {1}" -f (Split-Path $file -Leaf), $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}
if ($failed -gt 0) { exit 1 }
Say '[+] подпись готова'
exit 0