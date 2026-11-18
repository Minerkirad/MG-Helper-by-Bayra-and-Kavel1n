# Rebuilds self-contained .bat files from their .ps1 sources.
# The .bat files embed the PowerShell as UTF-16LE base64 (-EncodedCommand),
# so editing the .ps1 alone is not enough - run this after any change.
# by Bayra & Kavel1n
$ErrorActionPreference = 'Stop'

$specs = @(
    @{
        Bat = '0-uninstall.bat'
        Src = 'uninstall.ps1'
        Header = @(
            '@echo off'
            'title Uninstall - by Bayra ^& Kavel1n'
        )
    }
    @{
        Bat = '2-reset-settings.bat'
        Src = 'reset-settings.ps1'
        Header = @(
            '@echo off'
            'title Reset settings - by Bayra ^& Kavel1n'
            'echo ============================================='
            'echo  Reset settings to MY current ones'
            'echo  by Bayra ^& Kavel1n'
            'echo ============================================='
            'echo.'
        )
    }
    @{
        Bat = '5-diagnose.bat'
        Src = 'diagnose.ps1'
        Header = @(
            '@echo off'
            'title Diagnose - by Bayra ^& Kavel1n'
            'echo ============================================='
            'echo  MG Helper Diagnose - by Bayra ^& Kavel1n'
            'echo ============================================='
            'echo.'
        )
    }
)

foreach ($s in $specs) {
    $srcPath = Join-Path $PSScriptRoot $s.Src
    if (-not (Test-Path -LiteralPath $srcPath)) {
        Write-Host "[!] missing source: $($s.Src)" -ForegroundColor Red
        continue
    }
    # read bytes and strip BOM deterministically (PS 5.1 BOM handling is unreliable here)
    $bytes = [IO.File]::ReadAllBytes($srcPath)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    $code = [Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))

    $lines = @($s.Header) + "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64"
    $bat   = ($lines -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot $s.Bat), $bat, [Text.Encoding]::ASCII)
    Write-Host "[+] $($s.Bat) rebuilt from $($s.Src) ($($code.Length) chars)"
}

Write-Host ""
Write-Host "Done. 3-import-settings.bat / 4-clean-cache.bat run the .ps1 directly,"
Write-Host "so their .ps1 files do not need to be baked into a bat."
pause