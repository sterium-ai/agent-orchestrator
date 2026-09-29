# Exercise the real runner with a fake CLI: no network, credentials or model invocation.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot=Join-Path $env:TEMP ('expert-runner-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$runner=Join-Path $root 'scripts/run-agent.ps1'
$fake=Join-Path $testRoot 'fake-cli.ps1'
$prompt=Join-Path $testRoot 'prompt.md'
$output=Join-Path $testRoot 'output.md'
$capture=Join-Path $testRoot 'arguments.json'
$oldClaude=$env:CLAUDE_COMMAND; $oldCodex=$env:CODEX_COMMAND; $oldCapture=$env:EXPERT_TEST_CAPTURE; $oldAppData=$env:APPDATA
$script:failures=0
function Check($name,$ok) { if($ok){Write-Host "PASS $name"}else{Write-Host "FAIL $name"; $script:failures++} }
try {
    @'
$argv=@($args)
$input | Out-Null
ConvertTo-Json -InputObject $argv | Set-Content -LiteralPath $env:EXPERT_TEST_CAPTURE -Encoding utf8
$i=[Array]::IndexOf($argv,'-o')
if($i -ge 0){ Set-Content -LiteralPath $argv[$i+1] -Value 'fake result' }
Write-Output 'fake result'
exit 0
'@ | Set-Content -LiteralPath $fake -Encoding utf8
    Set-Content -LiteralPath $prompt -Value 'fixture'
    $env:CLAUDE_COMMAND=$fake; $env:CODEX_COMMAND=$fake; $env:EXPERT_TEST_CAPTURE=$capture; $env:APPDATA=$testRoot
    function Run-Fixture($provider,$mode,[switch]$Expert,[string]$Model='',[string]$Shell='',[string]$Writable='') {
        if(Test-Path -LiteralPath $capture){Remove-Item -LiteralPath $capture}
        $options=@(); if($Expert){$options+='-ExpertSession'}
        if($Model){$options+=@('-ExpertModel',$Model)}
        if($Shell){$options+=@('-ShellCommands',$Shell)}
        if($Writable){$options+=@('-SandboxWritableDirs',$Writable)}
        $ErrorActionPreference='Continue'
        $messages = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $runner -Provider $provider -Mode $mode -PromptFile $prompt -WorkDir $testRoot -OutputFile $output -ExtraDirs (Join-Path $testRoot 'no-assets') @options 2>&1)
        $ErrorActionPreference='Stop'
        $script:lastExit=$LASTEXITCODE
        if($script:lastExit -ne 0 -and -not $Expert){Write-Host ($messages -join "`n"); if(Test-Path "$output.log"){Write-Host (Get-Content "$output.log" -Raw)}}
        if(Test-Path -LiteralPath $capture){$captured=Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json; foreach($arg in $captured){Write-Output $arg}; return}
        return @()
    }
    $normal=@(Run-Fixture 'codex' 'edit')
    Check 'Normal Codex keeps workspace sandbox and default model' ($script:lastExit -eq 0 -and $normal -contains 'workspace-write' -and $normal -notcontains '--model' -and $normal -notcontains '--dangerously-bypass-approvals-and-sandbox')
    $expert=@(Run-Fixture 'codex' 'edit' -Expert -Model 'fixture-codex-model')
    Check 'Expert Codex uses the configured model, medium and full access' ($script:lastExit -eq 0 -and $expert -contains 'fixture-codex-model' -and $expert -contains 'model_reasoning_effort=medium' -and $expert -contains '--dangerously-bypass-approvals-and-sandbox' -and $expert -notcontains '--sandbox')
    $expertDefault=@(Run-Fixture 'codex' 'edit' -Expert)
    Check 'Expert Codex without a configured model uses the CLI default model' ($script:lastExit -eq 0 -and $expertDefault -notcontains '--model' -and $expertDefault -contains '--dangerously-bypass-approvals-and-sandbox')
    $claude=@(Run-Fixture 'claude' 'edit' -Expert -Model 'fixture-claude-model')
    Check 'Expert Claude uses the configured model, medium and full access' ($script:lastExit -eq 0 -and $claude -contains 'fixture-claude-model' -and $claude -contains '--effort' -and $claude -contains 'medium' -and $claude -contains '--dangerously-skip-permissions')
    $normalClaude=@(Run-Fixture 'claude' 'edit')
    Check 'Normal Claude keeps existing permissions and model' ($script:lastExit -eq 0 -and $normalClaude -contains 'acceptEdits' -and $normalClaude -notcontains '--model' -and $normalClaude -notcontains '--dangerously-skip-permissions')
    Check 'Normal Claude allows the default shell commands' ($normalClaude -contains 'Bash(python:*)' -and $normalClaude -contains 'Bash(powershell:*)')
    $shellClaude=@(Run-Fixture 'claude' 'readonly' -Shell 'npm;node;bad command')
    Check 'Configured shell commands replace the defaults, also for a reviewer' ($script:lastExit -eq 0 -and $shellClaude -contains 'Bash(npm:*)' -and $shellClaude -contains 'Bash(node:*)' -and $shellClaude -notcontains 'Bash(python:*)')
    Check 'A shell command that is not a plain name is dropped' (@($shellClaude | Where-Object { $_ -like '*bad command*' }).Count -eq 0)
    Check 'A reviewer never gets write or commit tools' ($shellClaude -notcontains 'Write' -and $shellClaude -notcontains 'Bash(git commit:*)')
    $writable=Join-Path $testRoot 'tool-data'
    $codexWritable=@(Run-Fixture 'codex' 'edit' -Writable $writable)
    Check 'Codex edit sessions get the configured sandbox-writable directories' ($script:lastExit -eq 0 -and $codexWritable -contains $writable -and (Test-Path -LiteralPath $writable))
    $denied=@(Run-Fixture 'codex' 'readonly' -Expert)
    Check 'Expert flag cannot grant full access to a reviewer' ($script:lastExit -ne 0 -and $denied.Count -eq 0)
} finally {
    $env:CLAUDE_COMMAND=$oldClaude; $env:CODEX_COMMAND=$oldCodex; $env:EXPERT_TEST_CAPTURE=$oldCapture; $env:APPDATA=$oldAppData
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\expert-runner-'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if($script:failures){exit 1}
Write-Output 'test-expert-runner: PASS'
