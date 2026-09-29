<#
.SYNOPSIS
Self-test for the last-visible-agent-action readers added to scripts/agent-supervisor.ps1
(Read-FileTail, Get-ClaudeLastAction, Get-CodexLastAction, Get-CopilotLastAction,
Get-LastAgentAction and their small helpers).

.DESCRIPTION
Locates each function's source with the PowerShell AST and defines it from its extent text at
this script's own top-level scope -- same technique as scripts/tests/test-live-heartbeat.ps1 --
so agent-supervisor.ps1 itself (module-level lock/poll-loop code) never runs. Feeds each reader
redacted, synthetic fixture data (never a real transcript) for all three providers and asserts
the exact kind/summary produced, that no fixture's long-form "prompt" or "model output" text
ever appears in a summary, and that a tail-read against a multi-megabyte file stays well under
200ms.

Prints one line per check starting with PASS or FAIL, then a summary line, and exits non-zero
if any check failed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$script:failCount = 0

function Test-Result([string]$Name, [bool]$Condition, [string]$Detail = "") {
    if ($Condition) {
        Write-Host "PASS $Name"
    } else {
        $line = "FAIL $Name"
        if ($Detail) { $line = "$line -- $Detail" }
        Write-Host $line
        $script:failCount++
    }
}

# ----------------------------------------------------------------------------- AST extraction
function Get-FunctionSource([string]$Path, [string]$FunctionName) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    $found = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName },
        $true
    ) | Select-Object -First 1
    if (-not $found) { throw "Could not find function '$FunctionName' in $Path via AST parsing." }
    return $found.Extent.Text
}

$supervisorPath = (Resolve-Path (Join-Path $PSScriptRoot "..\agent-supervisor.ps1")).Path

$FunctionNames = @(
    "Read-FileTail", "Limit-Summary",
    "ConvertTo-ClaudeToolAction", "Get-ClaudeLastAction",
    "Get-CodexActionDetail", "ConvertTo-CodexToolAction", "Get-CodexSessionCwd", "Get-NormalizedWorkDir", "Get-CodexLastAction",
    "Test-CopilotNoiseChar", "Test-CopilotNoiseLine", "ConvertTo-CopilotLineAction", "Get-CopilotLastAction",
    "Get-LastAgentAction"
)
$script:funcSource = @{}
foreach ($fn in $FunctionNames) {
    try {
        $script:funcSource[$fn] = Get-FunctionSource $supervisorPath $fn
    } catch {
        Write-Host "FAIL Function extraction: $fn (scripts/agent-supervisor.ps1) -- unexpected error: $($_.Exception.Message)"
        $script:failCount++
    }
}

# Get-LastAgentAction calls Write-Log; $statePath is read directly (dynamic scope) by
# Get-CopilotLastAction, exactly like Write-Live/Invoke-Agent read it in the real file.
$script:logLines = New-Object System.Collections.Generic.List[string]
function Write-Log([string]$Message) { $script:logLines.Add($Message) }
foreach ($fn in $FunctionNames) {
    if ($script:funcSource.ContainsKey($fn)) {
        try {
            . ([scriptblock]::Create($script:funcSource[$fn]))
        } catch {
            Write-Host "FAIL Function definition: $fn -- unexpected error: $($_.Exception.Message)"
            $script:failCount++
        }
    }
}

$testRoot = Join-Path $env:TEMP "test-last-action-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$statePath = Join-Path $testRoot "state"
New-Item -ItemType Directory -Force -Path $statePath | Out-Null

$originalUserProfile = $env:USERPROFILE
$env:USERPROFILE = Join-Path $testRoot "home"
New-Item -ItemType Directory -Force -Path $env:USERPROFILE | Out-Null

# Long-form filler standing in for a real prompt and a real free-form model reply. Never written
# to any location a reader actually consumes as its summary source, so its absence from every
# summary demonstrates the "tool names/paths/short commands only" rule rather than assuming it.
$hugeBashDescription = ("This sentence simulates a full free-form model turn that must never leak into a 120-character heartbeat summary. " * 5)
$hugeDiffFiller = ("+ this line stands in for real diff body text that must never leak into a short summary. " * 10)
$hugeCopilotBlob = "This paragraph simulates a long free-form assistant reply that must not leak into the heartbeat summary. " * 4

function New-ClaudeJsonlDir([string]$WorkDir) {
    $slug = ($WorkDir -replace '[:\\]', '-')
    $dir = Join-Path $env:USERPROFILE ".claude\projects\$slug"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function New-ClaudeToolLine([string]$Name, [hashtable]$ToolInput, [string]$Timestamp) {
    $obj = [pscustomobject]@{
        type = "assistant"
        timestamp = $Timestamp
        message = [pscustomobject]@{
            role = "assistant"
            content = @([pscustomobject]@{ type = "tool_use"; id = "toolu_fixture"; name = $Name; input = $ToolInput })
        }
    }
    return ($obj | ConvertTo-Json -Depth 8 -Compress)
}

function New-ClaudeTextLine([string]$Text, [string]$Timestamp) {
    $obj = [pscustomobject]@{
        type = "assistant"
        timestamp = $Timestamp
        message = [pscustomobject]@{
            role = "assistant"
            content = @([pscustomobject]@{ type = "text"; text = $Text })
        }
    }
    return ($obj | ConvertTo-Json -Depth 8 -Compress)
}

# ----------------------------------------------------------------------------- Limit-Summary truncation
try {
    $long = "x" * 500
    $limited = Limit-Summary $long
    Test-Result "Limit-Summary: truncates to <= 120 chars" ($limited.Length -le 120)
    Test-Result "Limit-Summary: truncated text ends with an ASCII marker, not a raw cut" ($limited.EndsWith("..."))
    Test-Result "Limit-Summary: leaves a short string untouched" ((Limit-Summary "short text") -eq "short text")
} catch {
    Write-Host "FAIL Limit-Summary fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Claude: Edit
try {
    $workDir = "C:\fakework\claude-edit"
    $dir = New-ClaudeJsonlDir $workDir
    New-ClaudeToolLine "Edit" @{ file_path = "C:\work\repo\scripts\core\example.js"; old_string = "unused"; new_string = "unused" } "2026-09-16T10:00:00.000Z" |
        Set-Content -Path (Join-Path $dir "session-edit.jsonl") -Encoding utf8
    $result = Get-ClaudeLastAction $workDir
    Test-Result "Get-ClaudeLastAction (Edit): kind=edit" ($result.kind -eq "edit")
    Test-Result "Get-ClaudeLastAction (Edit): summary carries the file_path" ($result.summary -eq "Edit C:\work\repo\scripts\core\example.js")
    Test-Result "Get-ClaudeLastAction (Edit): summary <= 120 chars" ($result.summary.Length -le 120)
} catch {
    Write-Host "FAIL Claude Edit fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Claude: Read
try {
    $workDir = "C:\fakework\claude-read"
    $dir = New-ClaudeJsonlDir $workDir
    New-ClaudeToolLine "Read" @{ file_path = "C:\work\repo\README.md" } "2026-09-16T10:01:00.000Z" |
        Set-Content -Path (Join-Path $dir "session-read.jsonl") -Encoding utf8
    $result = Get-ClaudeLastAction $workDir
    Test-Result "Get-ClaudeLastAction (Read): kind=read" ($result.kind -eq "read")
    Test-Result "Get-ClaudeLastAction (Read): summary carries the path" ($result.summary -eq "Read C:\work\repo\README.md")
} catch {
    Write-Host "FAIL Claude Read fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Claude: Bash
try {
    $workDir = "C:\fakework\claude-bash"
    $dir = New-ClaudeJsonlDir $workDir
    New-ClaudeToolLine "Bash" @{ command = "git status --porcelain"; description = $hugeBashDescription } "2026-09-16T10:02:00.000Z" |
        Set-Content -Path (Join-Path $dir "session-bash.jsonl") -Encoding utf8
    $result = Get-ClaudeLastAction $workDir
    Test-Result "Get-ClaudeLastAction (Bash): kind=run" ($result.kind -eq "run")
    Test-Result "Get-ClaudeLastAction (Bash): summary is the short command line" ($result.summary -eq "Bash git status --porcelain")
    Test-Result "Get-ClaudeLastAction (Bash): the long free-form description never leaks" (-not $result.summary.Contains($hugeBashDescription))
} catch {
    Write-Host "FAIL Claude Bash fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Claude: latest tool_use wins, trailing text is skipped
try {
    $workDir = "C:\fakework\claude-latest"
    $dir = New-ClaudeJsonlDir $workDir
    $lines = @(
        (New-ClaudeToolLine "Read" @{ file_path = "C:\work\repo\a.js" } "2026-09-16T10:03:00.000Z"),
        (New-ClaudeToolLine "Bash" @{ command = "npm test -- --runInBand" } "2026-09-16T10:03:05.000Z"),
        (New-ClaudeTextLine "Ran the checks; all good." "2026-09-16T10:03:06.000Z")
    )
    Set-Content -Path (Join-Path $dir "session-latest.jsonl") -Value $lines -Encoding utf8
    $result = Get-ClaudeLastAction $workDir
    Test-Result "Get-ClaudeLastAction (multi-line): returns the latest tool_use, not an earlier one" ($result.kind -eq "run" -and $result.summary -eq "Bash npm test -- --runInBand")
    Test-Result "Get-ClaudeLastAction (multi-line): a trailing text-only line does not override the last real tool action" ($result.summary -notmatch "Ran the checks")
} catch {
    Write-Host "FAIL Claude multi-line fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: shell function_call (wrapped payload shape)
function New-CodexHome([string]$Name) {
    $codexHomeDir = Join-Path $testRoot "codex-$Name"
    New-Item -ItemType Directory -Force -Path (Join-Path $codexHomeDir "sessions\2026\09\16") | Out-Null
    return $codexHomeDir
}

# Every real Codex rollout JSONL opens with a "session_meta" line naming the cwd the session was
# launched in (see Get-CodexSessionCwd in agent-supervisor.ps1); a fixture without one would never
# be found by the new WorkDir-scoped lookup.
function New-CodexSessionMetaLine([string]$Cwd, [string]$Timestamp) {
    return ([pscustomobject]@{
        timestamp = $Timestamp
        type = "session_meta"
        payload = [pscustomobject]@{ id = [Guid]::NewGuid().ToString(); cwd = $Cwd; originator = "codex_cli_rs" }
    } | ConvertTo-Json -Depth 8 -Compress)
}

try {
    $workDir = "C:\fakework\codex-shell"
    $codexHome = New-CodexHome "shell"
    $argsJson = (@{ command = @("bash", "-lc", "git status --porcelain") } | ConvertTo-Json -Compress)
    $line = [pscustomobject]@{
        timestamp = "2026-09-16T11:00:00.000Z"
        type = "response_item"
        payload = [pscustomobject]@{ type = "function_call"; name = "shell"; arguments = $argsJson }
    } | ConvertTo-Json -Depth 8 -Compress
    $lines = @((New-CodexSessionMetaLine $workDir "2026-09-16T10:59:00.000Z"), $line)
    Set-Content -Path (Join-Path $codexHome "sessions\2026\09\16\rollout-shell.jsonl") -Value $lines -Encoding utf8
    $result = Get-CodexLastAction $workDir $codexHome
    Test-Result "Get-CodexLastAction (shell function_call): kind=run" ($result.kind -eq "run")
    Test-Result "Get-CodexLastAction (shell function_call): summary is the short command line" ($result.summary -eq "shell bash -lc git status --porcelain")
} catch {
    Write-Host "FAIL Codex shell fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: exec_command (top-level, unwrapped shape)
try {
    $workDir = "C:\fakework\codex-exec"
    $codexHome = New-CodexHome "exec"
    $line = [pscustomobject]@{
        timestamp = "2026-09-16T11:01:00.000Z"
        type = "exec_command"
        command = "npm test -- --runInBand"
    } | ConvertTo-Json -Compress
    $lines = @((New-CodexSessionMetaLine $workDir "2026-09-16T10:59:00.000Z"), $line)
    Set-Content -Path (Join-Path $codexHome "sessions\2026\09\16\rollout-exec.jsonl") -Value $lines -Encoding utf8
    $result = Get-CodexLastAction $workDir $codexHome
    Test-Result "Get-CodexLastAction (exec_command): kind=run" ($result.kind -eq "run")
    Test-Result "Get-CodexLastAction (exec_command): summary is the short command line" ($result.summary -eq "exec_command npm test -- --runInBand")
} catch {
    Write-Host "FAIL Codex exec_command fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: exec_command using the real "cmd" array field, not "command"
try {
    $workDir = "C:\fakework\codex-cmdarray"
    $codexHome = New-CodexHome "cmdarray"
    $line = [pscustomobject]@{
        timestamp = "2026-09-16T11:01:30.000Z"
        type = "exec_command"
        cmd = @("bash", "-lc", "npm test -- --watch=false")
    } | ConvertTo-Json -Compress
    $lines = @((New-CodexSessionMetaLine $workDir "2026-09-16T10:59:00.000Z"), $line)
    Set-Content -Path (Join-Path $codexHome "sessions\2026\09\16\rollout-cmdarray.jsonl") -Value $lines -Encoding utf8
    $result = Get-CodexLastAction $workDir $codexHome
    Test-Result "Get-CodexLastAction (exec_command with cmd array): kind=run" ($result.kind -eq "run")
    Test-Result "Get-CodexLastAction (exec_command with cmd array): summary is the short command line" ($result.summary -eq "exec_command bash -lc npm test -- --watch=false")
} catch {
    Write-Host "FAIL Codex cmd-array fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: a bare, non-JSON "arguments" string still resolves (unchanged fallback behaviour)
try {
    $workDir = "C:\fakework\codex-bareargs"
    $codexHome = New-CodexHome "bareargs"
    $line = [pscustomobject]@{
        timestamp = "2026-09-16T11:01:45.000Z"
        type = "response_item"
        payload = [pscustomobject]@{ type = "function_call"; name = "shell"; arguments = "git status --porcelain" }
    } | ConvertTo-Json -Depth 8 -Compress
    $lines = @((New-CodexSessionMetaLine $workDir "2026-09-16T10:59:00.000Z"), $line)
    Set-Content -Path (Join-Path $codexHome "sessions\2026\09\16\rollout-bareargs.jsonl") -Value $lines -Encoding utf8
    $result = Get-CodexLastAction $workDir $codexHome
    Test-Result "Get-CodexLastAction (bare non-JSON arguments): kind=run" ($result.kind -eq "run")
    Test-Result "Get-CodexLastAction (bare non-JSON arguments): summary is the short command line" ($result.summary -eq "shell git status --porcelain")
} catch {
    Write-Host "FAIL Codex bare-arguments fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: apply_patch function_call maps to edit, diff body never leaks
try {
    $workDir = "C:\fakework\codex-patch"
    $codexHome = New-CodexHome "patch"
    $argsJson = (@{ file_path = "scripts/core/foo.js"; diff = $hugeDiffFiller } | ConvertTo-Json -Compress)
    $line = [pscustomobject]@{
        timestamp = "2026-09-16T11:02:00.000Z"
        type = "response_item"
        payload = [pscustomobject]@{ type = "function_call"; name = "apply_patch"; arguments = $argsJson }
    } | ConvertTo-Json -Depth 8 -Compress
    $lines = @((New-CodexSessionMetaLine $workDir "2026-09-16T10:59:00.000Z"), $line)
    Set-Content -Path (Join-Path $codexHome "sessions\2026\09\16\rollout-patch.jsonl") -Value $lines -Encoding utf8
    $result = Get-CodexLastAction $workDir $codexHome
    Test-Result "Get-CodexLastAction (apply_patch): kind=edit" ($result.kind -eq "edit")
    Test-Result "Get-CodexLastAction (apply_patch): summary carries the file path" ($result.summary -eq "apply_patch scripts/core/foo.js")
    Test-Result "Get-CodexLastAction (apply_patch): the full diff body never leaks" (-not $result.summary.Contains($hugeDiffFiller))
} catch {
    Write-Host "FAIL Codex apply_patch fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: apply_patch carrying its patch body in "input" (the real shape), never leaks the patch
try {
    $workDir = "C:\fakework\codex-patchinput"
    $codexHome = New-CodexHome "patchinput"
    $patchInput = "*** Begin Patch`n*** Update File: scripts/core/bar.js`n@@`n-old line`n+new line ($hugeDiffFiller)`n*** End Patch"
    $argsJson = (@{ input = $patchInput } | ConvertTo-Json -Compress)
    $line = [pscustomobject]@{
        timestamp = "2026-09-16T11:02:30.000Z"
        type = "response_item"
        payload = [pscustomobject]@{ type = "function_call"; name = "apply_patch"; arguments = $argsJson }
    } | ConvertTo-Json -Depth 8 -Compress
    $lines = @((New-CodexSessionMetaLine $workDir "2026-09-16T10:59:00.000Z"), $line)
    Set-Content -Path (Join-Path $codexHome "sessions\2026\09\16\rollout-patchinput.jsonl") -Value $lines -Encoding utf8
    $result = Get-CodexLastAction $workDir $codexHome
    Test-Result "Get-CodexLastAction (apply_patch via input): kind=edit" ($result.kind -eq "edit")
    Test-Result "Get-CodexLastAction (apply_patch via input): summary carries only the file path" ($result.summary -eq "apply_patch scripts/core/bar.js")
    Test-Result "Get-CodexLastAction (apply_patch via input): the patch body never leaks" (-not $result.summary.Contains($hugeDiffFiller) -and -not $result.summary.Contains("Begin Patch"))
} catch {
    Write-Host "FAIL Codex apply_patch-via-input fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: an unrecognized payload shape never leaks its raw JSON
try {
    $workDir = "C:\fakework\codex-unknown"
    $codexHome = New-CodexHome "unknown"
    $argsJson = (@{ foo = "bar"; secretToken = "fake-secret-should-never-appear" } | ConvertTo-Json -Compress)
    $line = [pscustomobject]@{
        timestamp = "2026-09-16T11:03:00.000Z"
        type = "response_item"
        payload = [pscustomobject]@{ type = "function_call"; name = "mystery_tool"; arguments = $argsJson }
    } | ConvertTo-Json -Depth 8 -Compress
    $lines = @((New-CodexSessionMetaLine $workDir "2026-09-16T10:59:00.000Z"), $line)
    Set-Content -Path (Join-Path $codexHome "sessions\2026\09\16\rollout-unknown.jsonl") -Value $lines -Encoding utf8
    $result = Get-CodexLastAction $workDir $codexHome
    Test-Result "Get-CodexLastAction (unrecognized shape): kind=unknown" ($result.kind -eq "unknown")
    Test-Result "Get-CodexLastAction (unrecognized shape): the raw arguments JSON never leaks" (-not $result.summary.Contains("secretToken") -and -not $result.summary.Contains("fake-secret-should-never-appear"))
} catch {
    Write-Host "FAIL Codex unrecognized-shape fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: WorkDir scoping picks the matching session, not the newest one on the host
try {
    $workDirA = "C:\fakework\codex-concurrent-a"
    $workDirB = "C:\fakework\codex-concurrent-b"
    $codexHome = New-CodexHome "concurrent"
    $lineA = [pscustomobject]@{
        timestamp = "2026-09-16T11:04:00.000Z"
        type = "exec_command"
        command = "echo from-task-a"
    } | ConvertTo-Json -Compress
    $lineB = [pscustomobject]@{
        timestamp = "2026-09-16T11:05:00.000Z"
        type = "exec_command"
        command = "echo from-task-b"
    } | ConvertTo-Json -Compress
    $fileA = Join-Path $codexHome "sessions\2026\09\16\rollout-concurrent-a.jsonl"
    $fileB = Join-Path $codexHome "sessions\2026\09\16\rollout-concurrent-b.jsonl"
    Set-Content -Path $fileA -Value @((New-CodexSessionMetaLine $workDirA "2026-09-16T11:03:00.000Z"), $lineA) -Encoding utf8
    Set-Content -Path $fileB -Value @((New-CodexSessionMetaLine $workDirB "2026-09-16T11:03:30.000Z"), $lineB) -Encoding utf8
    # File B is the more recently written session on the host -- the old "just take the newest
    # file" logic would report task B's action even when asked about task A.
    (Get-Item $fileA).LastWriteTime = (Get-Date).AddMinutes(-5)
    (Get-Item $fileB).LastWriteTime = (Get-Date)
    $result = Get-CodexLastAction $workDirA $codexHome
    Test-Result "Get-CodexLastAction (concurrent sessions): scopes to the requested WorkDir, not the newest file" ($result.summary -eq "exec_command echo from-task-a")
} catch {
    Write-Host "FAIL Codex concurrent-session fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Codex: a matching session older than 30 unrelated, more-recently-written sessions is still found
try {
    $workDirOld = "C:\fakework\codex-buried"
    $codexHome = New-CodexHome "buried"
    $sessDir = Join-Path $codexHome "sessions\2026\09\16"
    $lineOld = [pscustomobject]@{
        timestamp = "2026-09-16T09:00:00.000Z"
        type = "exec_command"
        command = "echo from-buried-task"
    } | ConvertTo-Json -Compress
    $fileOld = Join-Path $sessDir "rollout-buried.jsonl"
    Set-Content -Path $fileOld -Value @((New-CodexSessionMetaLine $workDirOld "2026-09-16T08:59:00.000Z"), $lineOld) -Encoding utf8
    (Get-Item $fileOld).LastWriteTime = (Get-Date).AddHours(-2)
    # 30 unrelated sessions, each written more recently than the one actually being asked about --
    # more than the old "only look at the 25 newest files" cap this test exists to prove is gone.
    for ($i = 0; $i -lt 30; $i++) {
        $unrelatedDir = "C:\fakework\codex-noise-$i"
        $lineNoise = [pscustomobject]@{
            timestamp = "2026-09-16T11:10:00.000Z"
            type = "exec_command"
            command = "echo noise-$i"
        } | ConvertTo-Json -Compress
        $fileNoise = Join-Path $sessDir "rollout-noise-$i.jsonl"
        Set-Content -Path $fileNoise -Value @((New-CodexSessionMetaLine $unrelatedDir "2026-09-16T11:09:00.000Z"), $lineNoise) -Encoding utf8
        (Get-Item $fileNoise).LastWriteTime = (Get-Date).AddMinutes(-$i)
    }
    $result = Get-CodexLastAction $workDirOld $codexHome
    Test-Result "Get-CodexLastAction (session buried under 30 newer ones): still finds the matching session" ($result.summary -eq "exec_command echo from-buried-task")
} catch {
    Write-Host "FAIL Codex buried-session fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# Built from code points, never written as literal non-ASCII bytes in this file, so the fixture
# does not depend on which codepage the .ps1 file happens to be read back with.
$spinnerA = [char]0x280B
$spinnerB = [char]0x2819
$spinnerC = [char]0x2839

# ----------------------------------------------------------------------------- Copilot: last real line looks like a run
try {
    $tag = "issue-1-implement"
    $stdoutLines = @(
        $spinnerA,
        $spinnerB,
        "`$ git commit -m ""apply redacted fix""",
        "",
        $spinnerC
    )
    Set-Content -Path (Join-Path $statePath "$tag.stdout.txt") -Value $stdoutLines -Encoding utf8
    $result = Get-CopilotLastAction $tag
    Test-Result "Get-CopilotLastAction (run-shaped line): kind=run" ($result.kind -eq "run")
    Test-Result "Get-CopilotLastAction (run-shaped line): trailing spinner/blank noise is skipped" ($result.summary -eq 'git commit -m "apply redacted fix"')
} catch {
    Write-Host "FAIL Copilot run-shaped fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Copilot: last real line looks like free-form prose -- sanitized, never echoed verbatim
try {
    $tag = "issue-2-implement"
    $realLine = "I reviewed the file and updated the docstring accordingly."
    $stdoutLines = @(
        $spinnerA,
        $hugeCopilotBlob,
        $realLine,
        "$spinnerB$spinnerC"
    )
    Set-Content -Path (Join-Path $statePath "$tag.stdout.txt") -Value $stdoutLines -Encoding utf8
    $result = Get-CopilotLastAction $tag
    Test-Result "Get-CopilotLastAction (message-shaped line): kind=message" ($result.kind -eq "message")
    Test-Result "Get-CopilotLastAction (message-shaped line): summary is a sanitized placeholder, not the line itself" ($result.summary -match '^agent message \(\d+ chars\)$')
    Test-Result "Get-CopilotLastAction (message-shaped line): the real line text never leaks into the summary" (-not $result.summary.Contains($realLine))
    Test-Result "Get-CopilotLastAction (message-shaped line): the earlier free-form blob never leaks" (-not $result.summary.Contains($hugeCopilotBlob))
} catch {
    Write-Host "FAIL Copilot message-shaped fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Copilot: prompt-shaped free-form text is sanitized, never echoed verbatim
try {
    $tag = "issue-9-implement"
    $promptLikeText = "Please refactor the inventory system to use the new item registry and keep tests passing."
    Set-Content -Path (Join-Path $statePath "$tag.stdout.txt") -Value @($promptLikeText) -Encoding utf8
    $result = Get-CopilotLastAction $tag
    Test-Result "Get-CopilotLastAction (prompt-shaped text): kind=message" ($result.kind -eq "message")
    Test-Result "Get-CopilotLastAction (prompt-shaped text): the prompt text never appears verbatim in the summary" ((-not $result.summary.Contains($promptLikeText)) -and ($result.summary -notmatch "inventory system"))
} catch {
    Write-Host "FAIL Copilot prompt-shaped fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- Copilot: stdout.txt is the live source and takes precedence over output.md
try {
    $tag = "issue-10-implement"
    # run-agent.ps1 now streams the Copilot CLI's output into "$tag.stdout.txt" as the process
    # runs (this task's fix) and only writes "$tag.output.md" once it exits. A stale/finished
    # output.md must never shadow a live stdout.txt, so this fixture makes the two disagree and
    # asserts the reader reports the stdout.txt content.
    Set-Content -Path (Join-Path $statePath "$tag.output.md") -Value @('$ echo stale-output-md-content') -Encoding utf8
    Set-Content -Path (Join-Path $statePath "$tag.stdout.txt") -Value @('$ echo live-stdout-content') -Encoding utf8
    $result = Get-CopilotLastAction $tag
    Test-Result "Get-CopilotLastAction (precedence): reads stdout.txt, not output.md, when both exist" ($result.summary -eq "echo live-stdout-content")
} catch {
    Write-Host "FAIL Copilot precedence fixture -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- dispatcher: Get-LastAgentAction routes by provider and never throws
try {
    $threw = $false
    $r1 = $null; $r2 = $null; $r3 = $null; $r4 = $null
    try {
        $r1 = Get-LastAgentAction -Provider "claude" -WorkDir "C:\fakework\claude-bash" -Tag "issue-3-implement"
        $r2 = Get-LastAgentAction -Provider "codex" -WorkDir "C:\fakework\codex-shell" -Tag "issue-4-implement" -CodexHome (Join-Path $testRoot "codex-shell")
        $r3 = Get-LastAgentAction -Provider "copilot" -WorkDir "C:\irrelevant" -Tag "issue-1-implement"
        $r4 = Get-LastAgentAction -Provider "claude" -WorkDir "C:\fakework\does-not-exist" -Tag "issue-5-implement"
    } catch { $threw = $true }
    Test-Result "Get-LastAgentAction: never throws across providers, including a missing transcript" (-not $threw)
    Test-Result "Get-LastAgentAction (claude): dispatches to the real Bash reader" ($r1.kind -eq "run" -and $r1.summary -eq "Bash git status --porcelain")
    Test-Result "Get-LastAgentAction (codex): dispatches to the real shell reader" ($r2.kind -eq "run" -and $r2.summary -eq "shell bash -lc git status --porcelain")
    Test-Result "Get-LastAgentAction (copilot): dispatches to the real stdout reader" ($r3.kind -eq "run" -and $r3.summary -eq 'git commit -m "apply redacted fix"')
    Test-Result "Get-LastAgentAction: a provider with nothing found yet returns the safe unknown placeholder" ($null -eq $r4.at -and $r4.kind -eq "unknown" -and $r4.summary -eq "")
    Test-Result "Get-LastAgentAction: logs a debug line timing the read" (@($script:logLines | Where-Object { $_ -match '\[debug\]' -and $_ -match 'lastAction read' }).Count -ge 4)
} catch {
    Write-Host "FAIL Get-LastAgentAction dispatcher checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

# ----------------------------------------------------------------------------- performance: tail read stays fast against a multi-megabyte file
try {
    $largeFile = Join-Path $testRoot "large-fixture.jsonl"
    $writer = New-Object System.IO.StreamWriter($largeFile, $false, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $filler = (New-ClaudeTextLine ("x" * 150) "2026-09-16T09:00:00.000Z")
        for ($i = 0; $i -lt 30000; $i++) { $writer.WriteLine($filler) }
        $writer.WriteLine((New-ClaudeToolLine "Edit" @{ file_path = "C:\work\repo\scripts\core\perf.js" } "2026-09-16T09:59:59.000Z"))
    } finally { $writer.Dispose() }
    $fileSizeMb = [Math]::Round((Get-Item $largeFile).Length / 1MB, 1)
    Test-Result "performance fixture is at least a few megabytes" ($fileSizeMb -ge 2) "size=${fileSizeMb}MB"

    $sw1 = [System.Diagnostics.Stopwatch]::StartNew()
    $tailText = Read-FileTail $largeFile 65536
    $sw1.Stop()
    Test-Result "Read-FileTail: tail read of a multi-MB file completes well under 200ms" ($sw1.Elapsed.TotalMilliseconds -lt 200) "elapsed=$($sw1.Elapsed.TotalMilliseconds)ms"
    Test-Result "Read-FileTail: never reads more than MaxBytes worth of text" ($tailText.Length -le 65536)

    $largeWorkDir = "C:\fakework\claude-perf"
    $dir = New-ClaudeJsonlDir $largeWorkDir
    Copy-Item $largeFile (Join-Path $dir "session-perf.jsonl") -Force

    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $perfResult = Get-ClaudeLastAction $largeWorkDir
    $sw2.Stop()
    Test-Result "Get-ClaudeLastAction: reading a multi-MB transcript completes well under 200ms" ($sw2.Elapsed.TotalMilliseconds -lt 200) "elapsed=$($sw2.Elapsed.TotalMilliseconds)ms"
    Test-Result "Get-ClaudeLastAction: still finds the real action inside a multi-MB file" ($perfResult.kind -eq "edit" -and $perfResult.summary -match "perf\.js")
} catch {
    Write-Host "FAIL Performance checks -- unexpected error: $($_.Exception.Message)"
    $script:failCount++
}

$env:USERPROFILE = $originalUserProfile
Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------- summary
Write-Host ""
if ($script:failCount -gt 0) {
    Write-Host "SUMMARY: $script:failCount check(s) FAILED"
    exit 1
} else {
    Write-Host "SUMMARY: all checks passed"
    exit 0
}
