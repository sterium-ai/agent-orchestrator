<#!
AST-only checks for supervisor live-status observation points.
#>
$ErrorActionPreference = "Stop"
$script:failures = 0
function Test-Result([string]$Name, [bool]$Condition) {
    if ($Condition) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL $Name"; $script:failures++ }
}

$path = Join-Path $PSScriptRoot "..\agent-supervisor.ps1"
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Test-Result "agent-supervisor.ps1 parses without errors" ($errors.Count -eq 0)

function Get-Function([string]$Name) {
    $ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
}
function Get-LiveCommands([System.Management.Automation.Language.Ast]$Root) {
    @($Root.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq "Write-Live"
    }, $true))
}
function Has-TryAncestor([System.Management.Automation.Language.Ast]$Node) {
    while ($Node) {
        if ($Node -is [System.Management.Automation.Language.TryStatementAst]) { return $true }
        $Node = $Node.Parent
    }
    return $false
}

foreach ($name in @("Invoke-Planning", "Invoke-Implementation", "Invoke-Review", "Invoke-Recovery", "Invoke-Reconciliation")) {
    $fn = Get-Function $name
    $calls = if ($fn) { Get-LiveCommands $fn } else { @() }
    $supervisorCalls = @($calls | Where-Object { $_.Extent.Text -match '(?i)-Role\s+[''\"]supervisor[''\"]' })
    Test-Result "$name contains a supervisor Write-Live call" ($supervisorCalls.Count -gt 0)
    Test-Result "$name supervisor Write-Live calls are guarded" (@($supervisorCalls | Where-Object { Has-TryAncestor $_ }).Count -eq $supervisorCalls.Count)
}

$topLevelCalls = @($ast.EndBlock.Statements | ForEach-Object { Get-LiveCommands $_ } | Where-Object { Has-TryAncestor $_ })
$idleCall = @($topLevelCalls | Where-Object { $_.Extent.Text -match '(?i)-Tag\s+[''\"]idle[''\"]' })
Test-Result "top-level idle branch contains a guarded Write-Live call" ($idleCall.Count -gt 0)

$allCalls = Get-LiveCommands $ast
$addedCalls = @($allCalls | Where-Object { $_.Extent.Text -match '(?i)-Role\s+[''\"]supervisor[''\"]' })
Test-Result "every supervisor Write-Live call is guarded" (@($addedCalls | Where-Object { Has-TryAncestor $_ }).Count -eq $addedCalls.Count)

if ($script:failures -gt 0) { exit 1 }
Write-Host "PASS summary: $($allCalls.Count) Write-Live call site(s) parsed"
exit 0
