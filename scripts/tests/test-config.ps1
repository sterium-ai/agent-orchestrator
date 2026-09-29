# Configuration handling of agent-supervisor.ps1: no default repository, the JSON file, and
# command-line overrides. Every supervisor run here stops at configuration validation, before
# the GitHub CLI is ever called.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$supervisor = Join-Path $root 'scripts/agent-supervisor.ps1'
$script:failures = 0
function Check($name, $ok, $detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:failures++ } }

$work = Join-Path $env:TEMP ('config-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Invoke-Supervisor([string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $supervisor + '" ' + ($Arguments -join ' ')
    $psi.WorkingDirectory = $work
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    # A PATH without gh proves validation happens before any GitHub call.
    $psi.EnvironmentVariables['GH_COMMAND'] = 'gh-does-not-exist-for-config-test'
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) { $p.Kill(); return @{ Code = -1; Text = 'timed out' } }
    return @{ Code = $p.ExitCode; Text = ($out.Result + "`n" + $err.Result) }
}

try {
    $r = Invoke-Supervisor @('-DryRun', '-Once')
    Check 'No repository and no configuration file: the supervisor refuses to start' ($r.Code -ne 0 -and $r.Text -match 'No repository configured') $r.Text

    $r = Invoke-Supervisor @('-Repository', 'not-a-repository', '-DryRun', '-Once')
    Check 'A malformed repository is rejected' ($r.Code -ne 0 -and $r.Text -match 'owner>/<name>') $r.Text

    Set-Content -Path (Join-Path $work 'broken.json') -Value '{ "repository": ' -Encoding ascii
    $r = Invoke-Supervisor @('-ConfigPath', 'broken.json', '-DryRun', '-Once')
    Check 'An invalid JSON configuration is reported as such' ($r.Code -ne 0 -and $r.Text -match 'not valid JSON') $r.Text

    $r = Invoke-Supervisor @('-ConfigPath', 'missing.json', '-DryRun', '-Once')
    Check 'A missing configuration file is reported' ($r.Code -ne 0 -and $r.Text -match 'Configuration file not found') $r.Text

    # A valid repository gets past configuration and stops at the GitHub CLI check instead.
    Set-Content -Path (Join-Path $work 'agent-orchestrator.json') -Value '{ "repository": "example-org/example-repo" }' -Encoding ascii
    $r = Invoke-Supervisor @('-DryRun', '-Once')
    Check 'agent-orchestrator.json in the working directory is picked up automatically' ($r.Code -ne 0 -and $r.Text -notmatch 'No repository configured' -and $r.Text -match "GitHub CLI 'gh' is required") $r.Text

    # --- Get-ConfigValue, extracted by AST
    $ast = [Management.Automation.Language.Parser]::ParseFile($supervisor, [ref]$null, [ref]$null)
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ConfigValue' }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
    $cfg = '{ "repository": "a/b", "testGate": { "command": "npm test", "timeoutSeconds": 900 }, "acceptance": { "trustedAuthors": ["alice", "bob"] } }' | ConvertFrom-Json
    Check 'Get-ConfigValue reads a top-level key' ((Get-ConfigValue $cfg 'repository') -eq 'a/b')
    Check 'Get-ConfigValue reads a nested key' ((Get-ConfigValue $cfg 'testGate.command') -eq 'npm test')
    Check 'Get-ConfigValue keeps numbers typed' ((Get-ConfigValue $cfg 'testGate.timeoutSeconds') -eq 900)
    Check 'Get-ConfigValue returns arrays' (@(Get-ConfigValue $cfg 'acceptance.trustedAuthors').Count -eq 2)
    Check 'Get-ConfigValue returns null for a missing key' ($null -eq (Get-ConfigValue $cfg 'models.copilot'))
    Check 'Get-ConfigValue returns null without a configuration' ($null -eq (Get-ConfigValue $null 'repository'))

    # --- the shipped example is valid JSON and names every documented section
    $example = Get-Content -Raw -Path (Join-Path $root 'agent-orchestrator.example.json') | ConvertFrom-Json
    Check 'The example configuration parses' ($null -ne $example)
    foreach ($key in @('repository', 'testGate.command', 'acceptance.trustedAuthors', 'models.claudeExpert', 'models.codexExpert', 'agents.shellCommands', 'ownership.protectedPaths')) {
        Check "The example configuration sets $key" ($null -ne (Get-ConfigValue $example $key))
    }
    $text = [IO.File]::ReadAllText($supervisor)
    foreach ($key in @('repository', 'testGate.command', 'testGate.timeoutSeconds', 'testGate.whenChanged', 'acceptance.trustedAuthors', 'acceptance.timeoutSeconds', 'models.claudeExpert', 'models.codexExpert', 'models.copilot', 'agents.shellCommands', 'agents.extraDirectories', 'agents.sandboxWritableDirectories', 'worktree.excludePaths', 'orphanSweep.processNames', 'lessonsFile', 'prePushCommand', 'ownership')) {
        Check "The supervisor reads configuration key $key" ($text.Contains("'$key'"))
    }
} finally {
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
if ($script:failures) { Write-Host "SUMMARY: $script:failures check(s) failed"; exit 1 }
Write-Host 'SUMMARY: all checks passed'
exit 0
