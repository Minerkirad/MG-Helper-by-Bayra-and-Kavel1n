# MG Helper Pester 5 suite (ROADMAP 4.1) - pure-function coverage.
# Windows-only (path semantics). Run:  Invoke-Pester -Path tests
# Requires Pester 5:  Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
BeforeAll {
    . (Join-Path $PSScriptRoot '..\common.ps1')
    $script:sbx = Join-Path $env:TEMP ("mg_pester_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $sbx | Out-Null
    $script:HelperDir = $sbx
    $script:ConfigFile = Join-Path $sbx 'config.json'
}
AfterAll {
    Remove-Item $sbx -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-GoldenKeyMatchPure (per-variant/per-GPU)' {
    It 'matches an identical setup' { Test-GoldenKeyMatchPure 'GTA V' 'gpuA' 'GTA V' 'gpuA' | Should -Be $true }
    It 'detects a game variant change' { Test-GoldenKeyMatchPure 'GTA V' 'gpuA' 'GTA V Enhanced' 'gpuA' | Should -Be $false }
    It 'detects a GPU change' { Test-GoldenKeyMatchPure 'GTA V' 'gpuA' 'GTA V' 'gpuB' | Should -Be $false }
    It 'is conservative with no recorded key' { Test-GoldenKeyMatchPure '' '' 'GTA V' 'gpuA' | Should -Be $null }
    It 'is conservative with unreadable identity' { Test-GoldenKeyMatchPure 'GTA V' 'gpuA' '' '' | Should -Be $null }
}

Describe 'Test-ValidSettingsXml (MG-CR-003)' {
    It 'accepts a valid Settings document' {
        $f = Join-Path $sbx 'ok.xml'
        [IO.File]::WriteAllText($f, '<?xml version="1.0"?><Settings><graphics/></Settings>')
        Test-ValidSettingsXml -Path $f | Should -Be $true
    }
    It 'rejects a torn document' {
        $f = Join-Path $sbx 'torn.xml'
        [IO.File]::WriteAllText($f, '<Settings><graphics/>')
        Test-ValidSettingsXml -Path $f | Should -Be $false
    }
    It 'rejects a wrong root' {
        $f = Join-Path $sbx 'wrong.xml'
        [IO.File]::WriteAllText($f, '<?xml version="1.0"?><NotSettings/>')
        Test-ValidSettingsXml -Path $f | Should -Be $false
    }
}

Describe 'Test-SameSettings (tri-state, MG-CR-015 structural)' {
    BeforeEach {
        $script:a = Join-Path $sbx 'cmp_a.xml'
        $script:b = Join-Path $sbx 'cmp_b.xml'
    }
    It 'is structural: whitespace and attribute order do not matter' {
        [IO.File]::WriteAllText($a, "<Settings>`r`n  <X value=`"1`" `n   Y=`"2`"`r`n />`r`n</Settings>")
        [IO.File]::WriteAllText($b, '<Settings><X Y="2" value="1" /></Settings>')
        Test-SameSettings $a $b | Should -Be $true
    }
    It 'detects a real change' {
        [IO.File]::WriteAllText($b, '<Settings><X value="2" /></Settings>')
        Test-SameSettings $a $b | Should -Be $false
    }
    It 'returns $null for unreadable files (not drift)' {
        Test-SameSettings $a (Join-Path $sbx 'nope.xml') | Should -Be $null
    }
}

Describe 'Test-AdoptCandidate (adopt matrix, MG-CR poisoning regression)' {
    It 'adopts a user change after our apply' { Test-AdoptCandidate $true $true $false $true | Should -Be $true }
    It 'never adopts without a successful apply this session' { Test-AdoptCandidate $true $true $false $false | Should -Be $false }
    It 'never adopts an unchanged file' { Test-AdoptCandidate $true $true $true $true | Should -Be $false }
    It 'never adopts an unreadable file' { Test-AdoptCandidate $true $true $null $true | Should -Be $false }
    It 'respects onExit=restore' { Test-AdoptCandidate $true $false $false $true | Should -Be $false }
}

Describe 'Test-GuardActive (launch window)' {
    It 'is active inside the window' { Test-GuardActive (Get-Date) 120 $true $true | Should -Be $true }
    It 'is OFF after the window' { Test-GuardActive (Get-Date).AddSeconds(-600) 120 $true $true | Should -Be $false }
    It 'respects the kill-switch' { Test-GuardActive (Get-Date) 120 $false $true | Should -Be $false }
    It 'is inactive without a session' { Test-GuardActive $null 120 $true $true | Should -Be $false }
}

Describe 'Get-ExeNamesFromCommandLine (REVIEW-#3)' {
    It 'ignores document paths' { Get-ExeNamesFromCommandLine 'notepad "C:\Games\GTA5\settings.xml"' | Should -Not -Contain 'GTA5' }
    It 'detects a renamed binary by its argument' { Get-ExeNamesFromCommandLine '"C:\G\Renamed.exe" -game "C:\GTA V\GTA5.exe"' | Should -Contain 'GTA5' }
    It 'handles quoted exe paths with spaces' { Get-ExeNamesFromCommandLine '"C:\Program Files\Rockstar Games\GTA V\GTA5.exe" -nobattleye' | Should -Contain 'GTA5' }
}

Describe 'Get-SettingsKeyValues + Show-SettingsDiff (ROADMAP 5.3)' {
    It 'extracts key/value pairs' {
        $m = Get-SettingsKeyValues -XmlText '<Settings><TextureQuality value="0" /><CityDensity value="1" /></Settings>'
        $m['TextureQuality'] | Should -Be '0'
        $m['CityDensity'] | Should -Be '1'
    }
    It 'counts real changes' {
        $old = '<Settings><A value="1" /><B value="2" /></Settings>'
        $new = '<Settings><A value="9" /><B value="2" /></Settings>'
        Show-SettingsDiff -OldText $old -NewText $new | Should -Be 1
    }
}

Describe 'Save-MgConfig (MG-CR-001)' {
    It 'round-trips and survives a replace' {
        $c = Get-MgConfig; $c.settingsXml = 'C:\p1.xml'; Save-MgConfig $c | Out-Null
        $c.settingsXml = 'C:\p2.xml'; Save-MgConfig $c | Out-Null
        (Get-MgConfig).settingsXml | Should -Be 'C:\p2.xml'
    }
}

Describe 'Write-Atomic (MG-CR-001/N1)' {
    It 'replaces an existing file' {
        $f = Join-Path $sbx 'atomic.xml'
        [IO.File]::WriteAllText($f, 'OLD')
        Write-Atomic -Path $f -Bytes ([Text.Encoding]::UTF8.GetBytes('NEW')) | Should -Be $true
        [IO.File]::ReadAllText($f) | Should -Be 'NEW'
    }
    It 'creates a new file' {
        $f = Join-Path $sbx 'atomic_new.xml'
        Write-Atomic -Path $f -Bytes ([Text.Encoding]::UTF8.GetBytes('NEW')) | Should -Be $true
        Test-Path $f | Should -Be $true
    }
}
