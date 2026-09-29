# Exercise the real gates with command execution stubbed; never runs GitHub or a model.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'scripts/lib/owned-paths-auto.ps1')
. (Join-Path $root 'scripts/lib/task-preflight.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/agent-supervisor.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Get-TestGateFailures','Get-MechanicalFailures','Get-FailureClass','Get-BudgetFailures')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$realBudget=${function:Get-BudgetFailures}
$fixture=Join-Path $env:TEMP ('review-gates-'+[guid]::NewGuid().ToString('N'))
$TestCommand='npm test'; $TestGateTimeoutSeconds=10; $TestGateWhenChanged=''; $script:failures=0
$script:OwnershipRules=New-OwnershipRules @{ protectedPaths=@('vendor/') }
function Check($name,$ok){if($ok){Write-Host "PASS $name"}else{Write-Host "FAIL $name"; $script:failures++}}
function Write-Log($Message){}
function Stop-OrphanedProcesses($Context){}
function Invoke-BoundedCommand($Executable,$Arguments,$Directory,$Timeout) {
    $script:calls++
    $script:lastTimeout=$Timeout
    if($script:throwCommand){throw 'fixture command failure'}
    return @{Code=$script:testCode;TimedOut=$script:testTimedOut;Output='fixture output'}
}
function Get-BudgetFailures($Worktree,$Changed){if($script:throwBudget){throw 'fixture budget reader failure'};return (& $realBudget $Worktree $Changed)}
function git {
    $script:gitCalls++
    $global:LASTEXITCODE=0
    if($args[0] -eq 'fetch'){$global:LASTEXITCODE=$script:fetchCode;return}
    if($args -contains '--name-only'){$global:LASTEXITCODE=$script:diffCode;return $script:changed}
}
function Reset-Fixture {
    $script:throwCommand=$false; $script:throwBudget=$false; $script:testTimedOut=$false
    $script:calls=0; $script:gitCalls=0; $script:fetchCode=0; $script:diffCode=0; $script:testCode=0
    $script:changed=@('src/app.js')
    $script:TestCommand='npm test'; $script:TestGateWhenChanged=''
}
try {
    New-Item -ItemType Directory -Force (Join-Path $fixture 'src') | Out-Null
    Set-Content (Join-Path $fixture 'src/app.js') 'fixture'

    # --- the test gate on its own
    Reset-Fixture
    $script:throwCommand=$true
    $errors=@(Get-TestGateFailures $fixture)
    Check 'A test-runner exception blocks review' ($errors.Count -gt 0 -and ($errors -join ' ') -like '*fixture command failure*')
    Check 'Runner failures use environment repair instead of a paid code correction' ((Get-FailureClass ($errors -join ' ')) -like 'environment:*')
    Reset-Fixture
    $script:testCode=1
    $errors=@(Get-TestGateFailures $fixture)
    Check 'A red test gate blocks review with its output' ($errors.Count -eq 1 -and ($errors -join ' ') -like '*failed (exit 1)*fixture output*')
    Check 'A red test gate is an author correction, not an environment failure' ($null -eq (Get-FailureClass ($errors -join ' ')))
    Reset-Fixture
    $script:testTimedOut=$true; $script:testCode=-2
    $errors=@(Get-TestGateFailures $fixture)
    Check 'A test gate timeout blocks review' ($errors.Count -eq 1 -and ($errors -join ' ') -like '*did not finish within 10 s*')
    Check 'A test that never exits is the author''s to fix' ($null -eq (Get-FailureClass ($errors -join ' ')))
    Reset-Fixture
    $script:testCode=-3
    $errors=@(Get-TestGateFailures $fixture)
    Check 'A test command that cannot start uses environment repair' ($script:calls -eq 1 -and (Get-FailureClass ($errors -join ' ')) -like 'environment:*')
    Reset-Fixture
    $errors=@(Get-TestGateFailures $fixture)
    Check 'A green test gate retains the normal path' ($errors.Count -eq 0 -and $script:calls -eq 1 -and $script:lastTimeout -eq 10)
    Reset-Fixture
    $errors=@(Get-TestGateFailures $fixture -Command '')
    Check 'No test command configured means no gate and no process' ($errors.Count -eq 0 -and $script:calls -eq 0)
    Reset-Fixture
    $errors=@(Get-TestGateFailures (Join-Path $fixture 'missing'))
    Check 'A missing checkout cannot pass the test gate' ($errors.Count -gt 0 -and $script:calls -eq 0 -and (Get-FailureClass ($errors -join ' ')) -like 'environment:*')

    # --- the gate inside the mechanical checks
    Reset-Fixture
    $script:testCode=1
    $errors=@(Get-MechanicalFailures $fixture)
    Check 'Mechanical checks run the test gate for a changed path' ($script:calls -eq 1 -and ($errors -join ' ') -like '*test gate*')
    Reset-Fixture
    $TestGateWhenChanged='^src/'
    $script:changed=@('docs/readme.md')
    $errors=@(Get-MechanicalFailures $fixture)
    Check 'The gate is skipped when no changed path matches testGate.whenChanged' ($errors.Count -eq 0 -and $script:calls -eq 0)
    Reset-Fixture
    $TestCommand=''
    $errors=@(Get-MechanicalFailures $fixture)
    Check 'Mechanical checks without a test command start no process' ($errors.Count -eq 0 -and $script:calls -eq 0)
    Reset-Fixture
    $script:changed=@('vendor/lib/x.js', 'src/app.js')
    $errors=@(Get-MechanicalFailures $fixture)
    Check 'A change to a protected path is reported before review' (($errors -join ' ') -like '*off-limits*vendor/lib/x.js*')
    Reset-Fixture
    $script:throwBudget=$true
    $errors=@(Get-MechanicalFailures $fixture)
    Check 'A mechanical-check exception blocks review' ($errors.Count -gt 0 -and ($errors -join ' ') -like '*fixture budget reader failure*')
    Reset-Fixture
    $script:fetchCode=1
    $errors=@(Get-MechanicalFailures $fixture)
    Check 'Failed fetch cannot validate against an unknown base' ($errors.Count -gt 0 -and $script:calls -eq 0)
    Check 'Failed fetch uses environment repair' ((Get-FailureClass ($errors -join ' ')) -like 'environment:*')
    Reset-Fixture
    $script:diffCode=1
    $errors=@(Get-MechanicalFailures $fixture)
    Check 'Failed changed-file discovery cannot skip validation' ($errors.Count -gt 0 -and $script:calls -eq 0)
    Reset-Fixture
    $errors=@(Get-MechanicalFailures (Join-Path $fixture 'missing-checkout'))
    Check 'A missing checkout cannot count as verified' ($errors.Count -gt 0 -and $script:calls -eq 0)
    Reset-Fixture
    $before=(Get-Location).Path
    $ErrorActionPreference='Continue' # The real supervisor's policy, including non-terminating errors.
    $errors=@(Get-MechanicalFailures (Join-Path $fixture 'src/app.js'))
    $ErrorActionPreference='Stop'
    Check 'A file checkout never validates the previous directory under Continue policy' ($errors.Count -gt 0 -and $script:calls -eq 0 -and (Get-Location).Path -eq $before)

    # Real budget reader, with an OS read-error boundary that is non-terminating unless
    # the caller explicitly requests Stop (as Get-Content normally behaves).
    New-Item -ItemType Directory -Force (Join-Path $fixture 'docs/architecture') | Out-Null
    $budgetPath=Join-Path $fixture 'docs/architecture/core-budgets.json'
    $corePath=Join-Path $fixture 'src/app.js'
    Set-Content $budgetPath '{"src/app.js":10}'
    function Get-Content {
        [CmdletBinding()] param([string]$Path,[switch]$Raw,[string]$Encoding)
        if([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($script:deniedPath)){Write-Error 'fixture file read denied';return}
        Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
    }
    $ErrorActionPreference='Continue'
    $script:deniedPath=$budgetPath
    $errors=@(& $realBudget $fixture @('src/app.js'))
    Check 'An unreadable budget file blocks under Continue policy' ($errors.Count -gt 0 -and (Get-FailureClass ($errors -join ' ')) -like 'environment:*')
    $script:deniedPath=$corePath
    $errors=@(& $realBudget $fixture @('src/app.js'))
    Check 'An unreadable budgeted file cannot silently skip its budget' ($errors.Count -gt 0 -and (Get-FailureClass ($errors -join ' ')) -like 'environment:*')
    $ErrorActionPreference='Stop'
    $script:deniedPath=Join-Path $fixture 'not-denied'
    $errors=@(& $realBudget $fixture @('src/app.js'))
    Check 'Readable budget and budgeted file retain successful validation' ($errors.Count -eq 0)
    Set-Content $corePath (1..12 | ForEach-Object { "line $_" })
    $errors=@(& $realBudget $fixture @('src/app.js'))
    Check 'A file over its budget is reported' ($errors.Count -eq 1 -and ($errors -join ' ') -like '*12 lines; its budget is 10*')
    $errors=@(& $realBudget $fixture @('docs/architecture/core-budgets.json'))
    Check 'Raising a budget without a decision record is reported' (($errors -join ' ') -like '*without a decision record*')
    $errors=@(& $realBudget $fixture @('docs/architecture/core-budgets.json', 'docs/decisions/005-grow-app.md'))
    Check 'Raising a budget with a decision record only reports the size' (-not (($errors -join ' ') -like '*without a decision record*'))
    $script:OwnershipRules=New-OwnershipRules @{ budgetsFile='' }
    $errors=@(& $realBudget $fixture @('src/app.js'))
    Check 'An empty budgetsFile disables the budget check' ($errors.Count -eq 0)
    $script:OwnershipRules=New-OwnershipRules @{ protectedPaths=@('vendor/') }
    Reset-Fixture
    function Push-Location {
        [CmdletBinding()] param([string]$LiteralPath)
        Write-Error 'fixture location denied'
    }
    $ErrorActionPreference='Continue'
    $errors=@(Get-MechanicalFailures $fixture)
    $ErrorActionPreference='Stop'
    Check 'Failure entering an existing checkout runs no Git or tests' ($errors.Count -gt 0 -and $script:gitCalls -eq 0 -and $script:calls -eq 0 -and (Get-Location).Path -eq $before)
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\review-gates-'
    if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if($script:failures){exit 1}
