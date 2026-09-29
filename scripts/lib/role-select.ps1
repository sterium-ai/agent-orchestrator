# Pure, dot-sourceable helpers for task role selection and the shared agent-prompt section.
# They read the caller's $promptDir (the prompt templates directory) when it is set.

# Prompt templates that are not author roles and can never be selected with `Role:`.
$script:ReservedPromptNames = @('planner', 'reviewer', 'repairer', 'lessons', 'expert-recovery', 'implementer')

# Reads the `Role:` field from a task issue body the same way `Provider:`/`Reviewer:` are read
# (via the caller's Get-Field helper). A role selects the author prompt `<role>.md` in the prompt
# templates directory, so a project can add specialised author prompts (a documentation writer,
# a data migrator) without code changes. A missing field, an unknown role, a reserved name or a
# name that is not a plain identifier falls back to "implementer".
function Get-TaskRole([string]$Body, [string]$PromptDirectory = $promptDir) {
    $role = Get-Field $Body "Role"
    if (-not $role) { return "implementer" }
    $name = $role.Trim().ToLowerInvariant()
    if ($name -notmatch '^[a-z][a-z0-9-]{0,39}$') { return "implementer" }
    if ($script:ReservedPromptNames -contains $name) { return "implementer" }
    if (-not $PromptDirectory -or -not (Test-Path -LiteralPath (Join-Path $PromptDirectory "$name.md"))) { return "implementer" }
    return $name
}

# Reads _agent-common.md fresh on every call, mirroring Get-LessonsSection's fresh read of
# lessons.md: the shared section can change between prompt fills within one run. Looks in the
# caller's prompt templates directory first and falls back to the copy shipped with the tool.
function Get-AgentCommonSection([string]$PromptDirectory = $promptDir) {
    $candidates = @()
    if ($PromptDirectory) { $candidates += (Join-Path $PromptDirectory "_agent-common.md") }
    $candidates += (Join-Path $PSScriptRoot "..\..\docs\agent-prompts\_agent-common.md")
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return (Get-Content -Raw -LiteralPath $path -Encoding utf8).TrimEnd() }
    }
    return ""
}
