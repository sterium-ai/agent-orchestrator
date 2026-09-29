# Real Git checkout + real branch resolver; external state/GitHub are fixture boundaries.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/agent-supervisor.ps1'),[ref]$null,[ref]$null)
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-IssueBranch'},$true)
. ([scriptblock]::Create($node.Extent.Text))
$report=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Report-Failure'},$true)
. ([scriptblock]::Create($report.Extent.Text))
$worktreeRoot=Join-Path $env:TEMP ('task-identity-'+[guid]::NewGuid().ToString('N'))
$testRoot=$worktreeRoot
$checkout=Join-Path $worktreeRoot 'issue-273'
$script:state=@{}; $script:prs=@(); $Repository='fixture/repo'; $script:failures=0
function Load-State($n,[ref]$Ok){if($Ok){$Ok.Value=$true};return $script:state}
function Invoke-GhJson($Arguments){return $script:prs}
function Write-Log($Message){}
function Set-IssueLabels($Number,$Remove,$Add){}
function Write-Live{}
function Get-Field($Body,$Name){return ''}
function Get-IssueRefs($Text){return @()}
function Find-PR($Branch){return $null}
function Comment($Number,$Message){$script:comment=$Message}
$L=@{Ready='agent-ready';Review='agent-review';Failed='agent-failed';InProgress='agent-in-progress';Blocked='agent-blocked'}
function Check($name,$ok){if($ok){Write-Host "PASS $name"}else{Write-Host "FAIL $name";$script:failures++}}
try{
    New-Item -ItemType Directory -Force -Path $checkout | Out-Null
    & git init --quiet $checkout
    & git -C $checkout symbolic-ref HEAD refs/heads/agent/issue-273-original-title
    $issue=[pscustomobject]@{number=273;title='Renamed after implementation'}
    Check 'Retitling a task preserves its actual branch' ((Get-IssueBranch $issue) -eq 'agent/issue-273-original-title')
    $script:state=@{branch='agent/issue-273-different'}
    $blocked=$false; try { Get-IssueBranch $issue | Out-Null } catch { $blocked=$true }
    Check 'Conflicting saved identity never silently replaces work' $blocked
    $script:state=@{}
    & git -C $checkout symbolic-ref HEAD refs/heads/agent/issue-2730-another-task
    $blocked=$false; try { Get-IssueBranch $issue | Out-Null } catch { $blocked=$true }
    Check 'Another task branch is rejected' $blocked
    $worktreeRoot=Join-Path $worktreeRoot 'missing-checkouts'
    $script:state=@{branch='agent/issue-273-original-title'}
    Check 'Missing checkout recovers persisted identity after rename' ((Get-IssueBranch $issue -Existing) -eq 'agent/issue-273-original-title')
    $script:state=@{}
    $script:prs=@(@{headRefName='agent/issue-2730-wrong'},@{headRefName='agent/issue-273-original-title'})
    Check 'Legacy missing checkout discovers exact issue PR' ((Get-IssueBranch $issue -Existing) -eq 'agent/issue-273-original-title')
    $script:prs+=@{headRefName='agent/issue-273-other'}
    $blocked=$false; try { Get-IssueBranch $issue -Existing | Out-Null } catch { $blocked=$true }
    Check 'Ambiguous PRs require explicit resolution' $blocked
    $script:prs=@()
    $blocked=$false; try { Get-IssueBranch $issue -Existing | Out-Null } catch { $blocked=$true }
    Check 'Missing existing identity never falls back to a renamed title' $blocked
    $script:prs=$null
    $blocked=$false; try { Get-IssueBranch $issue -Existing | Out-Null } catch { $blocked=$true }
    Check 'Failed PR lookup never invents an existing identity' $blocked
    Report-Failure $issue 'fixture failure'
    Check 'Unverified branch identity never recommends rebuilding the task' ($script:comment.Contains('do not add `agent-ready` or recreate the branch'))
    Check 'New task retains initial title-derived naming' ((Get-IssueBranch $issue) -eq 'agent/issue-273-renamed-after-implementation')
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\task-identity-'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if($script:failures){exit 1}
