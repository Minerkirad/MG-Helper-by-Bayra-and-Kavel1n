# validate-contracts.ps1 - validates MG Helper JSON files against docs\contracts\*.schema.json
# PS 5.1, no external dependencies: implements the subset of JSON Schema the project uses
# (type, const, enum, pattern, minimum, required, properties, additionalProperties, items).
#
# Usage:
#   . .\tools\validate-contracts.ps1                            # dot-source: Test-JsonAgainstSchema & friends
#   .\tools\validate-contracts.ps1 -SelfTest                     # schemas themselves: valid JSON + $schema/$id/title
#   .\tools\validate-contracts.ps1 -Schema <p> -Data <p>         # validate one file, exit 1 on violation
[CmdletBinding()]
param(
    [string]$Schema,
    [string]$Data,
    [switch]$SelfTest
)

function Get-SchemaType([object]$Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return 'number' }
    if ($Value -is [System.Collections.IDictionary]) { return 'object' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    if ($Value -is [System.Collections.IEnumerable]) { return 'array' }
    return 'object'
}

function Test-JsonAgainstSchema {
    # Returns a list of human-readable violations (empty list = the document is valid).
    param(
        [object]$Data,
        [object]$Schema,
        [string]$Path = '$',
        [System.Collections.Generic.List[string]]$Inherited
    )
    $errs = $Inherited
    if ($null -eq $errs) { $errs = New-Object System.Collections.Generic.List[string] }
    if ($null -eq $Schema) { return $errs }
    $names = @($Schema.PSObject.Properties.Name)
    $actual = Get-SchemaType $Data

    if ($names -contains 'type') {
        $allowed = @($Schema.type)
        $ok = $false
        foreach ($t in $allowed) {
            if ($t -eq 'integer') {
                if ($actual -eq 'number' -and ([double]$Data -eq [Math]::Floor([double]$Data))) { $ok = $true }
            } elseif ($t -eq 'number') {
                if ($actual -eq 'number') { $ok = $true }
            } elseif ($t -eq $actual) {
                $ok = $true
            }
        }
        if (-not $ok) { $errs.Add("$Path`: expected type [$($allowed -join ', ')] but got '$actual'") }
    }

    if ($names -contains 'const') {
        if (-not ($Data -eq $Schema.const)) { $errs.Add("$Path`: expected const '$($Schema.const)' but got '$Data'") }
    }

    if ($names -contains 'enum') {
        $found = $false
        foreach ($e in @($Schema.enum)) { if ($actual -eq 'string' -and $Data -eq $e) { $found = $true } }
        if (-not $found) { $errs.Add("$Path`: value '$Data' is not one of [$(@($Schema.enum) -join ', ')]") }
    }

    if (($actual -eq 'string') -and ($names -contains 'pattern')) {
        if (-not [regex]::IsMatch([string]$Data, [string]$Schema.pattern)) {
            $errs.Add("$Path`: '$Data' does not match pattern '$($Schema.pattern)'")
        }
    }

    if (($actual -eq 'number') -and ($names -contains 'minimum')) {
        if ([double]$Data -lt [double]$Schema.minimum) { $errs.Add("$Path`: $Data is below minimum $($Schema.minimum)") }
    }

    if ($actual -eq 'object') {
        $keys = @($Data.PSObject.Properties.Name)
        if ($names -contains 'required') {
            foreach ($r in @($Schema.required)) {
                if ($keys -notcontains $r) { $errs.Add("$Path`: missing required field '$r'") }
            }
        }
        $declared = @()
        if ($names -contains 'properties') { $declared = @($Schema.properties.PSObject.Properties.Name) }
        if ($names -contains 'additionalProperties' -and $Schema.additionalProperties -eq $false) {
            foreach ($k in $keys) {
                if ($declared -notcontains $k) { $errs.Add("$Path`: unexpected field '$k' (additionalProperties=false)") }
            }
        }
        foreach ($p in $declared) {
            if ($keys -contains $p) {
                $null = Test-JsonAgainstSchema -Data $Data.$p -Schema $Schema.properties.$p -Path "$Path.$p" -Inherited $errs
            }
        }
    }

    if ($actual -eq 'array' -and ($names -contains 'items')) {
        $i = 0
        foreach ($item in $Data) {
            $null = Test-JsonAgainstSchema -Data $item -Schema $Schema.items -Path "$Path[$i]" -Inherited $errs
            $i++
        }
    }

    return $errs
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "file not found: $Path" }
    return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json)
}

function Get-ContractSchema([string]$Name) {
    # loads docs\contracts\<name>.schema.json relative to the package root
    $p = Join-Path (Join-Path $PSScriptRoot '..\docs\contracts') "$Name.schema.json"
    return (Read-JsonFile $p)
}

function Test-ContractFile {
    param([string]$SchemaPath, [string]$DataPath)
    $schema = Read-JsonFile $SchemaPath
    $data = Read-JsonFile $DataPath
    return (Test-JsonAgainstSchema -Data $data -Schema $schema)
}

function Test-SchemaSelfTest {
    # A schema must be readable JSON with $schema and $id - otherwise readers silently
    # validate against nothing.
    $problems = New-Object System.Collections.Generic.List[string]
    $dir = Join-Path $PSScriptRoot '..\docs\contracts'
    foreach ($f in (Get-ChildItem $dir -Filter '*.schema.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $s = Read-JsonFile $f.FullName
            if (-not $s.'$schema') { $problems.Add("$($f.Name): no `$schema") }
            if (-not $s.'$id') { $problems.Add("$($f.Name): no `$id") }
            if (-not $s.title) { $problems.Add("$($f.Name): no title") }
        } catch { $problems.Add("$($f.Name): not valid JSON - $($_.Exception.Message)") }
    }
    return $problems
}

# CLI mode: only when executed, not when dot-sourced by tools\check.ps1
if ($MyInvocation.InvocationName -ne '.') {
    if ($SelfTest) {
        $problems = Test-SchemaSelfTest
        if (@($problems).Count -gt 0) { $problems | ForEach-Object { "FAIL $_" }; exit 1 }
        'OK - all schemas have $schema/$id/title and parse'
        exit 0
    }
    if ($Schema -and $Data) {
        $v = Test-ContractFile -SchemaPath $Schema -DataPath $Data
        if (@($v).Count -gt 0) { $v | ForEach-Object { "FAIL $_" }; exit 1 }
        "OK - $Data matches $(Split-Path $Schema -Leaf)"
        exit 0
    }
    Write-Host 'usage: validate-contracts.ps1 -SelfTest | -Schema <schema.json> -Data <data.json>'
    exit 2
}