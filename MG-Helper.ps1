# MG Helper menu - by Bayra & Kavel1n
$host.UI.RawUI.WindowTitle = 'MG Helper - by Bayra & Kavel1n'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = $PSScriptRoot

# remove Mark-of-the-Web from package files (downloaded archives get flagged)
Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

function Show-Menu {
    Clear-Host
    Write-Host "=========================================================="
    Write-Host "           MG Helper - by Bayra & Kavel1n"
    Write-Host "=========================================================="
    Write-Host ""
    Write-Host "  [1] Установка          (запустить один раз)"
    Write-Host "  [2] Reset settings     (текущие настройки станут защищёнными)"
    Write-Host "  [3] Import settings    (импорт settings.xml из этой папки)"
    Write-Host "  [4] MAX FPS            (экстремальный профиль производительности)"
    Write-Host "  [5] Cut shadows        (вырезание теней как у друга)"
    Write-Host "  [6] Очистка кэша       (ВНИМАНИЕ: перекачка десятков ГБ)"
    Write-Host ""
    Write-Host "  [7] Диагностика + отчёт (если что-то не работает)"
    Write-Host "  [8] Удалить всё"
    Write-Host ""
    Write-Host "  [0] Выход"
    Write-Host ""
}

function Run-Bat([string]$Name) {
    & cmd /c "`"$(Join-Path $root $Name)`"" 2>&1 | ForEach-Object { Write-Host $_ }
}

while ($true) {
    Show-Menu
    $choice = Read-Host "Выбери пункт"
    switch ($choice) {
        '1' { & cmd /c "`"$(Join-Path $root '1-install.bat')`"" ; Write-Host ""; Read-Host "Нажми Enter, чтобы вернуться в меню" }
        '2' { & cmd /c "`"$(Join-Path $root '2-reset-settings.bat')`"" }
        '3' { & cmd /c "`"$(Join-Path $root '3-import-settings.bat')`"" }
        '4' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'max-fps.ps1') }
        '5' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'cut-shadows.ps1') }
        '6' { & cmd /c "`"$(Join-Path $root '4-clean-cache.bat')`"" }
        '7' { & cmd /c "`"$(Join-Path $root '5-diagnose.bat')`"" }
        '8' {
            & cmd /c "`"$(Join-Path $root '0-uninstall.bat')`""
            Write-Host ""
            Write-Host "Удалено. Эту папку можно удалить."
            Read-Host "Нажми Enter для выхода"
            exit 0
        }
        '0' { exit 0 }
        default { }
    }
}
