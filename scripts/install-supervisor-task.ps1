<#
.SYNOPSIS
Registers (or refreshes) the Windows scheduled task that keeps the agent supervisor running.

.DESCRIPTION
Run once from the main clone of the TARGET repository (the one whose issues drive the pipeline):

    powershell -ExecutionPolicy Bypass -File <tool>\scripts\install-supervisor-task.ps1 `
        -ConfigPath .\agent-orchestrator.json -Start

The task starts at every logon of the current user, restarts itself if it stops, and runs
hidden. The computer must stay powered on and the user logged in (locking the screen is fine).
Logs go to <state directory>\supervisor.log and <state directory>\task-*.txt in that clone.

    -Uninstall   removes the task
    -Start       starts it immediately after registering
    -TaskName    defaults to "AgentSupervisor"; use one name per target repository
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Start,
    [string]$TaskName = "AgentSupervisor",
    # The target repository's main clone. Defaults to the current directory.
    [string]$RepositoryPath = "",
    # Configuration file handed to the supervisor (relative to the repository path or absolute).
    [string]$ConfigPath = "",
    [string]$StateDirectory = ".agent-state",
    [int]$PollSeconds = 120
)

$ErrorActionPreference = "Stop"
$repo = if ($RepositoryPath) { (Resolve-Path -LiteralPath $RepositoryPath).Path } else { (Get-Location).Path }
$script = Join-Path $PSScriptRoot "agent-supervisor.ps1"
if (-not (Test-Path -LiteralPath $script)) { throw "$script not found next to this installer." }
if (-not (Test-Path -LiteralPath (Join-Path $repo ".git"))) { throw "$repo is not a git clone; run this from the target repository's main clone or pass -RepositoryPath." }

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output "Removed scheduled task '$TaskName'."
    return
}

$stateDir = if ([System.IO.Path]::IsPathRooted($StateDirectory)) { $StateDirectory } else { Join-Path $repo $StateDirectory }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$wrapper = Join-Path $stateDir "supervisor-loop.cmd"

# Batch files are read in the console's OEM code page. The wrapper is written in that code page,
# and refused if a path cannot be represented in it (it would be corrupted silently otherwise).
$oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
foreach ($p in @($repo, $script, $stateDir, $ConfigPath)) {
    if ($p -and $oem.GetString($oem.GetBytes($p)) -ne $p) { throw "The path '$p' cannot be written to a batch file in code page $($oem.CodePage); move it to a path with plain characters." }
}
$configArg = if ($ConfigPath) { " -ConfigPath `"$ConfigPath`"" } else { "" }
$stateArg = if ($StateDirectory -ne ".agent-state") { " -StateDirectory `"$StateDirectory`"" } else { "" }

# A tiny wrapper so stdout/stderr of the supervisor end up in files even when hidden.
#
# The log files are opened by cmd.exe with a share mode that admits no second writer, and every
# descendant of the supervisor inherits those handles. A child that outlives its run (a test tool
# an agent started that never exited) therefore keeps the canonical file locked, and a plain
# `>> task-stdout.txt` would fail -- so the supervisor would never be relaunched after a
# self-update exit. Each turn first probes the canonical names and falls back to a rotated name
# when one is locked; the supervisor kills such leaked holders at startup, so the turn after that
# is back on the canonical names.
#
# Changing this template changes nothing on a machine that is already running the wrapper:
# cmd.exe keeps executing the file it started with (by byte offset, so never edit a running
# wrapper in place). Re-run this installer to regenerate it; that re-registers and restarts the
# task, so do it while the supervisor is idle.
$lines = @(
    "@echo off",
    "cd /d `"$repo`"",
    ":loop",
    "set `"OUT=$stateDir\task-stdout.txt`"",
    "set `"ERR=$stateDir\task-stderr.txt`"",
    "(type nul >> `"%OUT%`") 2>nul || set `"OUT=$stateDir\task-stdout.%RANDOM%.txt`"",
    "(type nul >> `"%ERR%`") 2>nul || set `"ERR=$stateDir\task-stderr.%RANDOM%.txt`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`"$configArg$stateArg -PollSeconds $PollSeconds >> `"%OUT%`" 2>> `"%ERR%`"",
    "echo %DATE% %TIME% supervisor exited with %ERRORLEVEL%, restarting in 60s >> `"%OUT%`"",
    "timeout /t 60 /nobreak > nul",
    "goto loop"
)
[System.IO.File]::WriteAllText($wrapper, (($lines -join "`r`n") + "`r`n"), $oem)

$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$wrapper`"" -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "Runs the agent supervisor (objective -> plan -> implement -> review -> merge) for $repo while the user is logged on." | Out-Null
Write-Output "Registered scheduled task '$TaskName' for $repo (starts at logon, restarts on failure)."

if ($Start) {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Output "Task state: $((Get-ScheduledTask -TaskName $TaskName).State); last run: $($info.LastRunTime)"
}
