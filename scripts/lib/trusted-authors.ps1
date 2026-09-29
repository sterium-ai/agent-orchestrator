# Pure, dot-sourceable helper that decides whether an issue may define commands the supervisor
# executes on the host (its `## Acceptance commands` block), and whether an objective may be
# planned at all. No dependency on agent-supervisor.ps1, `gh`, or any other script's state.
#
# Acceptance commands run on the host, outside every agent sandbox (see the "Security model"
# section of README.md). Whoever can write an issue body can therefore choose what runs on the
# machine. With an allowlist configured (`acceptance.trustedAuthors`), only these people count:
#
#   - the issue's author and, when the body was edited, its last editor;
#   - for a task the supervisor itself created (the planner writes task issues with the
#     supervisor's own GitHub account), the author and last editor of its parent objective,
#     because the planner derived the commands from that objective's text.
#
# The supervisor's own login is always trusted as author/editor of a task issue (it created or
# repaired it), never as a substitute for checking the objective behind it.
#
# $Actors is a list of @{ Role; Login } in the order they should be reported. An actor with an
# empty Login is a missing editor (never edited) and is skipped, except for the "author" roles,
# where a missing login (a deleted account, a failed lookup) is untrusted.
#
# Returns [pscustomobject]@{ Trusted = <bool>; Reason = <string> }.
function Test-AcceptanceAuthority {
    param(
        [AllowEmptyCollection()][string[]]$TrustedAuthors = @(),
        [string]$SelfLogin = '',
        [AllowEmptyCollection()][object[]]$Actors = @()
    )
    $allow = @($TrustedAuthors | ForEach-Object { ([string]$_).Trim().TrimStart('@').ToLowerInvariant() } | Where-Object { $_ })
    if ($allow.Count -eq 0) {
        return [pscustomobject]@{ Trusted = $true; Reason = 'no trusted-authors allowlist is configured' }
    }
    $self = ([string]$SelfLogin).Trim().ToLowerInvariant()
    foreach ($actor in @($Actors)) {
        if (-not $actor) { continue }
        $role = [string]$(if ($actor -is [hashtable]) { $actor['Role'] } else { $actor.Role })
        $login = ([string]$(if ($actor -is [hashtable]) { $actor['Login'] } else { $actor.Login })).Trim().TrimStart('@')
        if (-not $login) {
            if ($role -match 'author') { return [pscustomobject]@{ Trusted = $false; Reason = "the $role could not be identified" } }
            continue
        }
        $key = $login.ToLowerInvariant()
        if ($allow -contains $key) { continue }
        if ($self -and $key -eq $self -and $role -notmatch 'objective') { continue }
        return [pscustomobject]@{ Trusted = $false; Reason = "the $role @$login is not in the trusted-authors allowlist" }
    }
    return [pscustomobject]@{ Trusted = $true; Reason = '' }
}

# Builds the actor list Test-AcceptanceAuthority expects from the identity records of a task issue
# and (optionally) its parent objective. Each record is @{ Author; Editor } as returned by the
# supervisor's GitHub lookup; $null means the lookup failed.
function Get-AcceptanceActors {
    param($Task, $Objective, [string]$SelfLogin = '', [bool]$HasObjective = $false)
    $actors = @()
    if ($null -eq $Task) { return @(@{ Role = 'issue author'; Login = '' }) }
    $actors += @{ Role = 'issue author'; Login = [string]$Task.Author }
    $actors += @{ Role = 'last editor of the issue'; Login = [string]$Task.Editor }
    $selfCreated = $SelfLogin -and ([string]$Task.Author).ToLowerInvariant() -eq $SelfLogin.ToLowerInvariant()
    if ($selfCreated -and $HasObjective) {
        if ($null -eq $Objective) { return @($actors + @(@{ Role = 'objective author'; Login = '' })) }
        $actors += @{ Role = 'objective author'; Login = [string]$Objective.Author }
        $actors += @{ Role = 'last editor of the objective'; Login = [string]$Objective.Editor }
    }
    return $actors
}
