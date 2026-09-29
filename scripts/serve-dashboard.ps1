<#
.SYNOPSIS
Serves the supervisor dashboard on http://localhost:<port>/ (loopback only, read-only).

.DESCRIPTION
Run from the target repository's main clone (where the supervisor writes its state):

    powershell -NoProfile -ExecutionPolicy Bypass -File <tool>\scripts\serve-dashboard.ps1

Routes:
  /                     docs/dashboard/index.html (shipped with this tool)
  /api/dashboard.json   <state directory>/dashboard.json (written every supervisor cycle)
  /api/live.json        <state directory>/live.json      (heartbeat of the running step)
  /api/status.json      <state directory>/status.json
Everything else is 404. Only GET is served, and only these fixed files: no directory listing,
no path from the request is ever joined onto the file system. Stop with Ctrl+C.
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$StateDirectory = ".agent-state"
)

$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$statePath = if ([System.IO.Path]::IsPathRooted($StateDirectory)) { $StateDirectory } else { Join-Path $root $StateDirectory }
$page = Join-Path $PSScriptRoot "..\docs\dashboard\index.html"
$routes = @{
    "/"                   = @{ Path = $page; Type = "text/html; charset=utf-8" }
    "/index.html"         = @{ Path = $page; Type = "text/html; charset=utf-8" }
    "/api/dashboard.json" = @{ Path = (Join-Path $statePath "dashboard.json"); Type = "application/json; charset=utf-8" }
    "/api/live.json"      = @{ Path = (Join-Path $statePath "live.json"); Type = "application/json; charset=utf-8" }
    "/api/status.json"    = @{ Path = (Join-Path $statePath "status.json"); Type = "application/json; charset=utf-8" }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Output "Dashboard: http://localhost:$Port/  (state: $statePath)  Ctrl+C to stop."
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $response = $context.Response
        try {
            $route = $routes[$context.Request.Url.AbsolutePath]
            if ($context.Request.HttpMethod -ne "GET") {
                $response.StatusCode = 405
            } elseif (-not $route -or -not (Test-Path -LiteralPath $route.Path -PathType Leaf)) {
                $response.StatusCode = 404
            } else {
                # FileShare.ReadWrite: the supervisor may be rewriting the file at this moment.
                $fs = [System.IO.File]::Open($route.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $response.ContentType = $route.Type
                    $response.Headers.Add("Cache-Control", "no-store")
                    $response.ContentLength64 = $fs.Length
                    $fs.CopyTo($response.OutputStream)
                } finally { $fs.Dispose() }
            }
        } catch {
            try { $response.StatusCode = 500 } catch { }
        } finally {
            $response.Close()
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
