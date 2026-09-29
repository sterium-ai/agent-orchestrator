# Self-test for scripts/lib/trusted-authors.ps1 and its use by the supervisor: who may define the
# acceptance commands the host executes. Never touches GitHub, launches no agent and runs no
# command from an issue body.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'scripts/lib/trusted-authors.ps1')
$script:failures = 0
function Check($name, $ok) { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name"; $script:failures++ } }

# --- Test-AcceptanceAuthority
$open = Test-AcceptanceAuthority -TrustedAuthors @() -SelfLogin 'bot' -Actors @(@{ Role = 'issue author'; Login = 'stranger' })
Check 'No allowlist: everything is trusted (previous behaviour)' ($open.Trusted)
$ok = Test-AcceptanceAuthority -TrustedAuthors @('alice') -Actors @(@{ Role = 'issue author'; Login = 'alice' }, @{ Role = 'last editor of the issue'; Login = '' })
Check 'A listed author with an unedited body is trusted' ($ok.Trusted)
$case = Test-AcceptanceAuthority -TrustedAuthors @('@Alice') -Actors @(@{ Role = 'issue author'; Login = 'alice' })
Check 'Logins compare case-insensitively and a leading @ is ignored' ($case.Trusted)
$stranger = Test-AcceptanceAuthority -TrustedAuthors @('alice') -Actors @(@{ Role = 'issue author'; Login = 'mallory' })
Check 'An unlisted author is not trusted' (-not $stranger.Trusted)
Check 'The reason names the unlisted author' ($stranger.Reason -like '*@mallory*not in the trusted-authors allowlist*')
$edited = Test-AcceptanceAuthority -TrustedAuthors @('alice') -Actors @(@{ Role = 'issue author'; Login = 'alice' }, @{ Role = 'last editor of the issue'; Login = 'mallory' })
Check 'A trusted author does not cover an untrusted last editor' (-not $edited.Trusted -and $edited.Reason -like '*last editor*@mallory*')
$ghost = Test-AcceptanceAuthority -TrustedAuthors @('alice') -Actors @(@{ Role = 'issue author'; Login = '' })
Check 'An author that cannot be identified is not trusted (fail closed)' (-not $ghost.Trusted)
$self = Test-AcceptanceAuthority -TrustedAuthors @('alice') -SelfLogin 'bot' -Actors @(@{ Role = 'issue author'; Login = 'bot' }, @{ Role = 'last editor of the issue'; Login = 'bot' })
Check 'The supervisor account is trusted as author/editor of a task issue' ($self.Trusted)
$selfObjective = Test-AcceptanceAuthority -TrustedAuthors @('alice') -SelfLogin 'bot' -Actors @(@{ Role = 'objective author'; Login = 'bot' })
Check 'The supervisor account is not a substitute for a trusted objective author' (-not $selfObjective.Trusted)

# --- Get-AcceptanceActors
$task = [pscustomobject]@{ Author = 'bot'; Editor = '' }
$objective = [pscustomobject]@{ Author = 'mallory'; Editor = '' }
$actors = @(Get-AcceptanceActors -Task $task -Objective $objective -SelfLogin 'bot' -HasObjective $true)
Check 'A planner-created task includes its objective''s author' (@($actors | Where-Object { $_.Role -eq 'objective author' -and $_.Login -eq 'mallory' }).Count -eq 1)
$verdict = Test-AcceptanceAuthority -TrustedAuthors @('alice') -SelfLogin 'bot' -Actors $actors
Check 'Commands the planner derived from an untrusted objective do not run' (-not $verdict.Trusted -and $verdict.Reason -like '*objective author @mallory*')
$trustedObjective = [pscustomobject]@{ Author = 'alice'; Editor = 'alice' }
$verdict2 = Test-AcceptanceAuthority -TrustedAuthors @('alice') -SelfLogin 'bot' -Actors @(Get-AcceptanceActors -Task $task -Objective $trustedObjective -SelfLogin 'bot' -HasObjective $true)
Check 'Commands the planner derived from a trusted objective run' ($verdict2.Trusted)
$missingObjective = Test-AcceptanceAuthority -TrustedAuthors @('alice') -SelfLogin 'bot' -Actors @(Get-AcceptanceActors -Task $task -Objective $null -SelfLogin 'bot' -HasObjective $true)
Check 'A failed objective lookup fails closed' (-not $missingObjective.Trusted)
$human = [pscustomobject]@{ Author = 'alice'; Editor = '' }
$humanActors = @(Get-AcceptanceActors -Task $human -Objective $null -SelfLogin 'bot' -HasObjective $true)
Check 'A task written by a person is judged on its own authors, not its objective' (@($humanActors | Where-Object { $_.Role -like 'objective*' }).Count -eq 0)
$failedTask = Test-AcceptanceAuthority -TrustedAuthors @('alice') -Actors @(Get-AcceptanceActors -Task $null -Objective $null)
Check 'A failed task lookup fails closed' (-not $failedTask.Trusted)

# --- Invoke-AcceptanceCommands never executes a skipped command
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/agent-supervisor.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Invoke-AcceptanceCommands', 'Format-AcceptanceReport', 'Resolve-AcceptanceCommand', 'Get-AcceptanceCommandDefect', 'Write-Utf8File')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Write-Live { }
function Write-Log($Message) { }
$AcceptanceTimeoutSeconds = 30
$statePath = Join-Path $env:TEMP ('trusted-authors-state-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $statePath | Out-Null
$marker = Join-Path $env:TEMP ("trusted-authors-" + [guid]::NewGuid().ToString('N') + ".txt")
$results = @(Invoke-AcceptanceCommands $env:TEMP @("Set-Content -Path '$marker' -Value pwned") -SkipReason 'the issue author @mallory is not in the trusted-authors allowlist')
Check 'A skipped command is never executed' (-not (Test-Path -LiteralPath $marker))
Check 'A skipped command counts as passed so no revision is spent on it' ($results.Count -eq 1 -and $results[0].Ok -and $results[0].Skipped)
$report = Format-AcceptanceReport $results $env:TEMP
Check 'The transcript labels the command as not run for an untrusted author' ($report -like '*NOT RUN (untrusted author)*@mallory*')
$ran = @(Invoke-AcceptanceCommands $env:TEMP @("Set-Content -Path '$marker' -Value ok"))
Check 'Without a skip reason the same command runs on the host' ((Test-Path -LiteralPath $marker) -and $ran[0].Ok -and -not $ran[0].Skipped)
Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $statePath -Recurse -Force -ErrorAction SilentlyContinue

# --- wiring
$review = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Review' }, $true).Extent.Text
Check 'Invoke-Review checks the authors before running acceptance commands' ($review.IndexOf('Get-AcceptanceAuthority') -ge 0 -and $review.IndexOf('Get-AcceptanceAuthority') -lt $review.IndexOf('Invoke-AcceptanceCommands'))
$planning = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Planning' }, $true).Extent.Text
Check 'Invoke-Planning refuses objectives from untrusted authors before the planner runs' ($planning.IndexOf('Test-AcceptanceAuthority') -ge 0 -and $planning.IndexOf('Test-AcceptanceAuthority') -lt $planning.IndexOf('Invoke-Agent'))

if ($script:failures) { Write-Host "SUMMARY: $script:failures check(s) failed"; exit 1 }
Write-Host "SUMMARY: all checks passed"
exit 0
