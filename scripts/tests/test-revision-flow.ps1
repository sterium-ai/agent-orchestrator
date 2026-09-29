# Exercise real repair/review/revision transitions with external effects stubbed.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/agent-supervisor.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Invoke-Repair','Invoke-Review','Invoke-Implementation','Get-IssueBranch','Get-Field','Get-IssueRefs','Get-OwnedPaths','Get-TaskReasoning','Limit-Text','Test-ReviewRunnable')) {
    $node = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
. (Join-Path $root 'scripts/lib/revision-flow.ps1')
. (Join-Path $root 'scripts/lib/workflow-policy.ps1')
. (Join-Path $root 'scripts/lib/expert-recovery.ps1')
. (Join-Path $root 'scripts/lib/owned-paths-auto.ps1')
. (Join-Path $root 'scripts/lib/task-preflight.ps1')
$script:OwnershipRules = New-OwnershipRules $null
$ClaudeExpertModel = 'claude-fable-5-1'; $CodexExpertModel = 'gpt-6-astra'
$statePath = Join-Path $env:TEMP ('revision-flow-' + [guid]::NewGuid().ToString('N'))
$worktreeRoot = $statePath
$logPath = Join-Path $statePath 'supervisor.log'
$worktree = Join-Path $statePath 'issue-7'
New-Item -ItemType Directory $worktree -Force | Out-Null
$L = @{Failed='failed'; Ready='ready'; InProgress='in-progress'; Review='review'}
$MaxRevisions=6; $MaxRepairs=2; $MaxTotalRevisions=12; $DocsReasoning='low'; $PlannerProvider='claude'
$Repository='fixture/repository'; $ImplementTimeoutMinutes=90
$promptDir = Join-Path $root 'docs/agent-prompts'
$script:failures=0
function Check($name,$ok) { if($ok){ Write-Host "PASS $name" }else{Write-Host "FAIL $name"; $script:failures++} }
function Write-Log($Message) {}
function Write-Live { param($Tag,$Provider,$StartedAtUtc,$Deadline,$Role,$Step,$Summary) }
function Comment($n,$Message) {}
function Load-State($n, [ref]$Ok) { if($Ok){$Ok.Value=$true}; return $script:state }
function Save-State($n,$st) { $script:state=$st; return $script:canSave }
function Get-Issue($n) { return $script:issue }
function Get-IssueProviders($Issue) { return $script:providers }
function Set-IssueProviders($Issue,$Author,$Reviewer) {
    if(-not $script:canAssign){return $false}
    $script:providers=@{Author=$Author;Reviewer=$Reviewer}; return $true
}
function Get-EffectiveReviewer($Issue) { $script:reviewerChecks++; return $null }
function Test-ProviderUsable($Provider) { if($Provider -in @('claude','codex')){return $script:authorReady}; return $false }
function Find-PR($Branch) { return @{number=70} }
function Invoke-GhJson($Arguments) { return @() }
function Get-LiveWorkerForIssue($n) { return $script:liveWorker }
function Report-Failure($Issue,$Message) { $script:reported=$Message }
function Set-IssueLabels($n,$Remove,$Add) { $script:labels=$Add }
function Set-IssueBody($n,$Body) { $script:issue.body=$Body; return $true }
function Read-Handoff($Worktree) { return 'Existing handoff' }
function Fill-Template($Name,$Values) { return 'fixture prompt' }
function Get-LessonsSection { return '' }
function Get-AgentCommonSection { return '' }
function Get-TaskRole($Body) { return 'implementer' }
function Git-Common-Dir($Worktree) { return $Worktree }
function Extract-Json($Output) { return $script:repairDecision }
function Register-QuotaBlock($Issue,$Author,$Run,$Stage) {}
function Validate-And-Push($Issue,$Worktree,$Branch,$Author) { $script:pushes++; return $null }
function Invoke-Agent {
    param($Provider,$Mode,$Prompt,$WorkDir,$Tag,$TimeoutMinutes,$ExtraWritableDirs,$CodexReasoning,[switch]$ExpertSession,[string]$ExpertModel)
    if($Mode -eq 'readonly') { $script:repairCalls++; return @{Ok=$true;Output='decision'} }
    $script:authorCalls++
    $script:launch=@{expert=[bool]$ExpertSession;provider=$Provider;effort=$CodexReasoning;timeout=$TimeoutMinutes;prompt=$Prompt;model=$ExpertModel}
    Check 'Push debt is persisted before a writer starts' ($script:state.pendingPush -and $script:state.awaitingRevisionBy -eq $Provider)
    return @{Ok=$true;QuotaBlocked=$script:quota;Unsafe=$false;TimedOut=$false}
}
function Reset-Fixture {
    $script:state=@{branch='agent/issue-7-tool-fix';revisions=6;totalRevisionAttempts=9;repairs=0;lastReviewedSha='old';lastVerdict='request_changes';lastBlockingFindings=@('broken save')}
    $script:issue=[pscustomobject]@{number=7;state='OPEN';title='Tool fix';body="Provider: claude`nReviewer: codex`n## Owned paths`n- scripts/example.ps1`n## Acceptance checks`n- preserves saves"}
    $script:authorCalls=0; $script:repairCalls=0; $script:pushes=0; $script:reviewerChecks=0
    $script:reported=''; $script:authorReady=$true; $script:canSave=$true; $script:quota=$false; $script:liveWorker=$null
    $script:ExpertRecoveryEnabled=$false; $script:providers=@{Author='claude';Reviewer='codex'}; $script:canAssign=$true
    $script:repairDecision=@{decision='rescope';explanation='allow missing save module';add_owned_paths=@('scripts/save.ps1')}
}
try {
    Reset-Fixture
    Invoke-Repair $script:issue 'scope' 'fix save' $worktree 'agent/7'
    Check 'Rescope queues author with existing findings' ($script:state.pendingRevision -and $script:state.awaitingRevisionBy -eq 'claude')
    Check 'Rescope never resets cumulative corrections' ($script:state.totalRevisionAttempts -eq 9)
    Check 'Repair invalidates old approval' ($null -eq $script:state.lastReviewedSha -and $null -eq $script:state.lastVerdict)
    Invoke-Review $script:issue
    Check 'Repaired task goes directly to author without paying reviewer' ($script:authorCalls -eq 1 -and $script:reviewerChecks -eq 0)
    Check 'Successful revision pushes and clears only completed debt' ($script:pushes -eq 1 -and -not $script:state.pendingRevision -and -not $script:state.pendingPush)
    Check 'Cumulative attempts increase once' ($script:state.totalRevisionAttempts -eq 10)
    Invoke-Review $script:issue
    Check 'Next cycle still requires independent review' ($script:reviewerChecks -eq 1 -and $script:authorCalls -eq 1)

    Reset-Fixture
    $script:authorReady=$false
    Invoke-TaskRevision $script:issue $script:state $worktree 'branch' 'claude' 2 6 'fix defect' 'codex' '' 'medium'
    Check 'Unavailable author retains pending correction without launching or charging' ($script:state.pendingRevision -and $script:state.awaitingRevisionBy -eq 'claude' -and $script:authorCalls -eq 0 -and $script:state.totalRevisionAttempts -eq 9)
    Check 'Quota waiting is gated on author, not reviewer' (-not (Test-ReviewRunnable $script:issue))

    Reset-Fixture
    $script:quota=$true
    Invoke-TaskRevision $script:issue $script:state $worktree 'branch' 'claude' 2 6 'fix defect' 'codex' '' 'medium'
    Check 'Quota refusal retains evidence, clears push debt, refunds correction' ($script:state.pendingRevision -and -not $script:state.pendingPush -and $script:state.totalRevisionAttempts -eq 9 -and $script:pushes -eq 0)

    Reset-Fixture
    $script:canSave=$false
    Invoke-TaskRevision $script:issue $script:state $worktree 'branch' 'claude' 2 6 'fix defect' 'codex' '' 'medium'
    Check 'Failed durable write never starts author' ($script:authorCalls -eq 0 -and $script:reported)

    Reset-Fixture
    $script:state.totalRevisionAttempts=12
    Invoke-TaskRevision $script:issue $script:state $worktree 'branch' 'claude' 2 6 'fix defect' 'codex' '' 'medium'
    Check 'Cumulative ceiling cannot be bypassed by reset round' ($script:authorCalls -eq 0 -and $script:reported -match 'Cumulative')

    Reset-Fixture
    $script:state.pendingRevision=@{text='fix';by='repair'}
    $script:state.pendingPush=$true
    $script:liveWorker=@{Confirmed=$true;File='worker.json'}
    Invoke-Review $script:issue
    Check 'Live surviving worker prevents another author or push' ($script:authorCalls -eq 0 -and $script:pushes -eq 0)
    $script:liveWorker=$null
    Invoke-Review $script:issue
    Check 'Recovery pushes owed commit before any review or relaunch' ($script:pushes -eq 1 -and $script:reviewerChecks -eq 0 -and $script:authorCalls -eq 0 -and -not $script:state.pendingRevision)

    Reset-Fixture
    $ExpertRecoveryEnabled=$true; $ExpertTimeoutMinutes=45
    Invoke-Repair $script:issue 'the same finding was restated three rounds in a row' 'save still broken' $worktree 'agent/7'
    Check 'Persistent defect queues expert correction instead of another repair diagnosis' ($script:state.pendingRevision.expert -and $script:repairCalls -eq 0)
    Invoke-Review $script:issue
    Check 'Expert correction launches at medium with bounded timeout' ($script:launch.expert -and $script:launch.effort -eq 'medium' -and $script:launch.timeout -eq 45)
    Check 'Expert budget recorded and correction still requires review' ($script:state.expertAttempts -eq 1 -and $script:reviewerChecks -eq 0 -and $script:pushes -eq 1)
    Check 'Old approval invalidated before expert writes' (-not $script:state.lastReviewedSha -and -not $script:state.lastVerdict)
    Invoke-Review $script:issue
    Check 'Expert result still goes to independent reviewer' ($script:reviewerChecks -eq 1)

    Reset-Fixture
    $ExpertRecoveryEnabled=$true; $script:quota=$true
    Invoke-Repair $script:issue 'the revision ceiling was reached' 'stuck' $worktree 'agent/7'
    Invoke-Review $script:issue
    Check 'Quota preserves specialist identity and refunds both budgets' ($script:state.pendingRevision.expert -and $script:state.pendingRevision.model -eq 'claude-fable-5-1' -and $script:state.expertAttempts -eq 0 -and $script:state.totalRevisionAttempts -eq 9 -and -not $script:state.pendingPush)
    $script:quota=$false
    Invoke-Review $script:issue
    Check 'Pending expert resumes as expert after quota' ($script:launch.expert -and $script:state.expertAttempts -eq 1)
    Check 'A second expert cannot be queued for same issue' (-not (Queue-ExpertRecovery $script:issue $script:state 'the revision ceiling was reached' 'still stuck' $worktree))

    Reset-Fixture
    $ExpertRecoveryEnabled=$true; $script:state.totalRevisionAttempts=12
    Invoke-TaskRevision $script:issue $script:state $worktree 'agent/7' 'claude' 2 6 'stuck at cap' 'codex' '' 'medium'
    Check 'Normal cumulative cap queues exactly one reserved expert opportunity' ($script:authorCalls -eq 0 -and $script:state.pendingRevision.expert)
    Invoke-Review $script:issue
    Check 'Expert beyond normal ceiling remains counted' ($script:state.totalRevisionAttempts -eq 13 -and $script:state.expertAttempts -eq 1)

    Reset-Fixture
    $ExpertRecoveryEnabled=$true; $script:state.repairs=2
    Check 'No writer recovery without an existing worktree' (-not (Queue-ExpertRecovery $script:issue $script:state 'preflight' 'broken task' ''))
    Invoke-Repair $script:issue 'repair budget exhausted' 'stuck' $worktree 'agent/7'
    $script:liveWorker=@{Confirmed=$true;File='worker.json'}
    Invoke-Review $script:issue
    Check 'Pending expert never duplicates a live worker' ($script:authorCalls -eq 0 -and $script:state.pendingRevision.expert)
    $script:liveWorker=$null; $script:authorReady=$false
    Invoke-Review $script:issue
    Check 'Unavailable expert waits without consuming its attempt' ($script:authorCalls -eq 0 -and $script:state.expertAttempts -ne 1 -and $script:state.pendingRevision.expert)

    Reset-Fixture
    $ExpertRecoveryEnabled=$true; $script:providers=@{Author='copilot';Reviewer='codex'}
    Invoke-Repair $script:issue 'the revision ceiling was reached' 'stuck' $worktree 'agent/7'
    $script:canAssign=$false
    Invoke-Review $script:issue
    Check 'Failed provider reassignment prevents expert launch' ($script:authorCalls -eq 0)
    $script:canAssign=$true
    Invoke-Review $script:issue
    Check 'Copilot task transfers to Astra with a different reviewer' ($script:launch.provider -eq 'codex' -and $script:providers.Reviewer -eq 'claude' -and $script:state.expertAttempts -eq 1)

    Reset-Fixture
    $ExpertRecoveryEnabled=$true; $script:canSave=$false
    Invoke-Repair $script:issue 'the revision ceiling was reached' 'stuck' $worktree 'agent/7'
    Check 'Failed expert intent persistence launches nothing' ($script:authorCalls -eq 0 -and $script:reported)

    Reset-Fixture
    $ExpertRecoveryEnabled=$true
    Invoke-Repair $script:issue 'the revision ceiling was reached' 'stuck' $worktree 'agent/7'
    $ExpertRecoveryEnabled=$false
    Invoke-Review $script:issue
    Check 'Disabling recovery blocks an already queued privileged session' ($script:authorCalls -eq 0 -and $script:state.pendingRevision.expert -and $script:reported)

    Reset-Fixture
    $script:canSave=$false; $script:recreated=0
    function Get-TaskContractFailures($Body) { return @() }
    function Get-EffectiveAuthor($Issue) { return $script:providers.Author }
    function Require-Command($Name) { return $true }
    function Remove-Worktree($Path) { $script:recreated++ }
    function New-AgentWorktree($Path,$Arguments,$Ref) { $script:recreated++; return $true }
    function git { $script:recreated++ }
    Invoke-Implementation $script:issue
    Check 'Failed branch persistence preserves checkout and launches no author' ($script:recreated -eq 0 -and $script:authorCalls -eq 0 -and $script:reported -like '*persist*')
} finally {
    $resolved=[IO.Path]::GetFullPath($statePath)
    $allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\revision-flow-'
    if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if($script:failures){exit 1}
Write-Output 'test-revision-flow: PASS'
