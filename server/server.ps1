# server.ps1 - HTTP listener for Oolio Migration Toolkit
# Serves UI + executes module scripts on http://localhost:<port>/.
# Port is supplied by Launch.ps1 (which probes for a free one); defaults to 8080.

param(
    [string]$ToolkitRoot,
    [int]$Port = 8080
)

if (-not $ToolkitRoot) { $ToolkitRoot = (Resolve-Path "$PSScriptRoot\..").Path }

$uiPath        = Join-Path $ToolkitRoot "ui"
$scriptsPath   = Join-Path $ToolkitRoot "scripts"
$progressPath  = Join-Path $ToolkitRoot "progress.json"
$routerScript  = Join-Path $ToolkitRoot "server\router.ps1"
$sharedScript  = Join-Path $scriptsPath "shared.ps1"

# Dot-source shared + router so their functions are available in this runspace
. $sharedScript
. $routerScript

# ----- Default progress.json (created on first run) -----
function Get-DefaultProgress {
    return @{
        bepoz = @{
            "read-registry"        = "pending"
            "terminate-processes"  = "pending"
            "stop-sql"             = "pending"
            "zip-data"             = "pending"
            "clear-startup"        = "pending"
            "check-run-key"        = "pending"
            "delete-registry"      = "pending"
            "consolidate-backups"  = "pending"
        }
        windows = @{
            "verify-autologon" = "pending"
            "enable-firewall"  = "pending"
            "active-hours"     = "pending"
            "harden-pos"       = "pending"
            "touch-input"      = "pending"
            "check-ip"         = "pending"
            "rename-device"    = "pending"
            "clean-desktop"    = "pending"
            "set-wallpaper"    = "pending"
        }
        dependencies = @{
            "check-chrome"          = "pending"
            "check-webview2"        = "pending"
            "teamviewer"            = "pending"
            "check-epsonnet-config" = "pending"
        }
        oolio = @{
            "deployment-config"  = "pending"
            "create-folders"     = "pending"
            "install-pos-chrome" = "pending"
            "install-cds-chrome" = "pending"
            "set-startup"        = "pending"
            "final-restart"      = "pending"
        }
        meta = @{
            terminalName    = ""
            terminalType    = ""
            hasCDS          = $false
            deploymentMode  = ""
            lastUpdated     = ""
        }
    }
}

if (-not (Test-Path $progressPath)) {
    Get-DefaultProgress | ConvertTo-Json -Depth 5 | Set-Content -Path $progressPath -Encoding UTF8
}

# ----- Reset stale 'running' statuses on startup -----
# If the toolkit was killed mid-step (browser closed, terminal rebooted, etc.) the step
# stays 'running' in progress.json forever. Rewrite any 'running' to 'error' so the UI
# surfaces it to the technician instead of looking confused.
function Reset-StaleRunningStatuses {
    param([string]$Path)
    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        $changed = 0
        foreach ($prop in $obj.PSObject.Properties) {
            if ($prop.Name -eq 'meta') { continue }
            $module = $prop.Value
            if ($null -eq $module) { continue }
            $staleNames = @()
            foreach ($step in $module.PSObject.Properties) {
                if ($step.Value -eq 'running') { $staleNames += $step.Name }
            }
            foreach ($name in $staleNames) {
                $module.PSObject.Properties.Item($name).Value = 'error'
                $changed++
                Write-Output "Reset stale 'running' on $($prop.Name)/$name -> 'error'"
            }
        }
        if ($changed -gt 0) {
            ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path $Path -Encoding UTF8
            Write-Output "Reset $changed stale running step(s)."
        }
    } catch {
        Write-Output "Could not reset stale statuses: $($_.Exception.Message)"
    }
}
Reset-StaleRunningStatuses -Path $progressPath

# ----- Per-session log file -----
# Tees every line of every step's output into C:\Oolio\Logs\session-<timestamp>.log so
# techs can attach the file to support tickets. The folder is created if missing -
# the toolkit may run before module 4's create-folders step.
$logsFolder = "C:\Oolio\Logs"
if (-not (Test-Path $logsFolder)) {
    try { New-Item -ItemType Directory -Path $logsFolder -Force | Out-Null } catch {}
}
$sessionStamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$sessionLogPath = Join-Path $logsFolder "session-$sessionStamp.log"

function Write-SessionLog {
    param([string]$Line)
    if (-not $sessionLogPath) { return }
    try { Add-Content -Path $sessionLogPath -Value $Line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

try {
    Write-SessionLog ("=" * 78)
    Write-SessionLog "Oolio Migration Toolkit session started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-SessionLog "Toolkit root: $ToolkitRoot"
    Write-SessionLog "Computer:     $env:COMPUTERNAME    User: $env:USERNAME"
    Write-SessionLog ("=" * 78)
} catch {}

# ----- HTTP Listener -----
# A bind failure here (e.g. http.sys URL ACL conflict) is a method-call exception,
# which PowerShell treats as non-terminating by default - the script would continue
# past the failed Start() and print a misleading "Listening on..." line. Wrap it in
# try/catch and exit so Launch.ps1 sees a clean failure and a clear job-output line.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try {
    $listener.Start()
} catch {
    Write-Output "ERROR: Could not bind http://localhost:$Port/ - $($_.Exception.Message)"
    Write-Output "Another process likely holds this port. Check with: Get-NetTCPConnection -LocalPort $Port -State Listen"
    exit 1
}
Write-Output "Listening on http://localhost:$Port/"
Write-Output "Session log: $sessionLogPath"

# ----- Helpers -----
function Write-TextResponse {
    param($Response, [string]$Body, [string]$ContentType = "text/plain", [int]$Status = 200)
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Write-FileResponse {
    param($Response, [string]$Path, [string]$ContentType)
    if (-not (Test-Path $Path)) {
        Write-TextResponse -Response $Response -Body "404 Not Found" -Status 404
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Response.StatusCode = 200
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Get-QueryValue {
    param($Query, [string]$Key)
    if (-not $Query) { return $null }
    $q = $Query.TrimStart('?')
    foreach ($pair in $q.Split('&')) {
        $kv = $pair.Split('=', 2)
        if ($kv[0] -eq $Key) {
            if ($kv.Length -eq 2) { return [System.Uri]::UnescapeDataString($kv[1]) }
            return ""
        }
    }
    return $null
}

function Send-SSE {
    param($Response, [string]$Data)
    # Each line in $Data becomes its own data: line, then a blank line terminates the event
    $payload = ""
    foreach ($line in ($Data -split "`r?`n")) {
        $payload += "data: $line`n"
    }
    $payload += "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Response.OutputStream.Flush()
    } catch {
        # Client disconnected
    }
}

function Invoke-StepStreaming {
    param($Response, [string]$ModuleId, [string]$StepId, [hashtable]$Params)

    $Response.StatusCode = 200
    $Response.ContentType = "text/event-stream"
    $Response.Headers.Add("Cache-Control", "no-cache")
    $Response.SendChunked = $true

    try {
        # Resolve module script path
        $scriptMap = @{
            "bepoz"        = "bepoz.ps1"
            "windows"      = "windows.ps1"
            "dependencies" = "dependencies.ps1"
            "oolio"        = "oolio.ps1"
        }
        if (-not $scriptMap.ContainsKey($ModuleId)) {
            Send-SSE -Response $Response -Data "__ERROR__: Unknown module '$ModuleId'"
            Send-SSE -Response $Response -Data "__DONE__"
            return
        }

        $moduleScriptPath = Join-Path $scriptsPath $scriptMap[$ModuleId]
        $functionName = Get-StepFunctionName -ModuleId $ModuleId -StepId $StepId
        if (-not $functionName) {
            Send-SSE -Response $Response -Data "__ERROR__: Unknown step '$StepId' in module '$ModuleId'"
            Send-SSE -Response $Response -Data "__DONE__"
            return
        }

        function Quote-PSLiteral($s) { if ($null -eq $s) { return "''" }; return "'" + ($s -replace "'", "''") + "'" }

        $value = $Params["value"]

        # Build a child-PowerShell command that dot-sources shared + module, then calls the function.
        # Output is line-buffered to stdout so we can stream it back as SSE.
        $argSegment = ""
        if ($StepId -eq "rename-device") {
            $argSegment = " -terminalName " + (Quote-PSLiteral $value)
        } elseif ($StepId -eq "set-wallpaper") {
            $argSegment = " -toolkitRoot " + (Quote-PSLiteral $ToolkitRoot)
        } elseif ($StepId -eq "verify-autologon") {
            $u = $Params["username"]; $p = $Params["password"]; $d = $Params["domain"]
            $argSegment = " -username " + (Quote-PSLiteral $u) + " -password " + (Quote-PSLiteral $p) + " -domain " + (Quote-PSLiteral $d)
        } elseif ($StepId -eq "active-hours") {
            $argSegment = " -updateHour " + (Quote-PSLiteral $value)
        }

        $command = ". '$sharedScript'; . '$moduleScriptPath'; $functionName$argSegment"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$command`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()

        Write-SessionLog ""
        Write-SessionLog ("--- {0} :: {1}/{2} ---" -f (Get-Date -Format 'HH:mm:ss'), $ModuleId, $StepId)

        # Stream stdout line by line, teeing each line to the session log.
        # __PROGRESS__: lines are UI-only ephemera (one JSON line per second per
        # long-running step) - skip them in the log file to keep it readable.
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if ($null -ne $line) {
                Send-SSE -Response $Response -Data $line
                if (-not $line.StartsWith('__PROGRESS__:')) {
                    Write-SessionLog $line
                }
            }
        }

        # Drain stderr
        $errOutput = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        if ($errOutput -and $errOutput.Trim().Length -gt 0) {
            foreach ($eline in ($errOutput -split "`r?`n")) {
                if ($eline.Trim().Length -gt 0) {
                    $tagged = "[ERROR] $eline"
                    Send-SSE -Response $Response -Data $tagged
                    Write-SessionLog $tagged
                }
            }
        }

        if ($proc.ExitCode -ne 0) {
            $exitMsg = "__ERROR__: Step exited with code $($proc.ExitCode)"
            Send-SSE -Response $Response -Data $exitMsg
            Write-SessionLog $exitMsg
        }

        Send-SSE -Response $Response -Data "__DONE__"
        Write-SessionLog ("--- {0} :: {1}/{2} done ---" -f (Get-Date -Format 'HH:mm:ss'), $ModuleId, $StepId)
    } catch {
        $errMsg = "__ERROR__: $($_.Exception.Message)"
        Send-SSE -Response $Response -Data $errMsg
        Write-SessionLog $errMsg
        Send-SSE -Response $Response -Data "__DONE__"
    } finally {
        try { $Response.OutputStream.Close() } catch {}
    }
}

# ----- Main request loop -----
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response
        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod

        try {
            switch -Regex ("$method $path") {
                '^GET /ping$' {
                    Write-TextResponse -Response $response -Body "OK"
                    break
                }
                '^GET /$' {
                    Write-FileResponse -Response $response -Path (Join-Path $uiPath "index.html") -ContentType "text/html; charset=utf-8"
                    break
                }
                '^GET /app\.js$' {
                    Write-FileResponse -Response $response -Path (Join-Path $uiPath "app.js") -ContentType "application/javascript; charset=utf-8"
                    break
                }
                '^GET /style\.css$' {
                    Write-FileResponse -Response $response -Path (Join-Path $uiPath "style.css") -ContentType "text/css; charset=utf-8"
                    break
                }
                '^GET /progress$' {
                    if (-not (Test-Path $progressPath)) {
                        Get-DefaultProgress | ConvertTo-Json -Depth 5 | Set-Content -Path $progressPath -Encoding UTF8
                    }
                    $body = Get-Content -Path $progressPath -Raw -Encoding UTF8
                    Write-TextResponse -Response $response -Body $body -ContentType "application/json; charset=utf-8"
                    break
                }
                '^POST /progress$' {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                    # Validate JSON before writing
                    try {
                        $null = $body | ConvertFrom-Json
                        Set-Content -Path $progressPath -Value $body -Encoding UTF8
                        Write-TextResponse -Response $response -Body '{"status":"ok"}' -ContentType "application/json"
                    } catch {
                        Write-TextResponse -Response $response -Body '{"status":"error","message":"invalid json"}' -ContentType "application/json" -Status 400
                    }
                    break
                }
                '^GET /run$' {
                    $moduleId = Get-QueryValue -Query $request.Url.Query -Key "module"
                    $stepId   = Get-QueryValue -Query $request.Url.Query -Key "step"
                    if (-not $moduleId -or -not $stepId) {
                        Write-TextResponse -Response $response -Body "Missing module or step parameter" -Status 400
                    } else {
                        $params = @{
                            value    = Get-QueryValue -Query $request.Url.Query -Key "value"
                            username = Get-QueryValue -Query $request.Url.Query -Key "username"
                            password = Get-QueryValue -Query $request.Url.Query -Key "password"
                            domain   = Get-QueryValue -Query $request.Url.Query -Key "domain"
                        }
                        Invoke-StepStreaming -Response $response -ModuleId $moduleId -StepId $stepId -Params $params
                    }
                    break
                }
                default {
                    Write-TextResponse -Response $response -Body "404 Not Found" -Status 404
                }
            }
        } catch {
            Write-Output "Request error: $($_.Exception.Message)"
            try { Write-TextResponse -Response $response -Body "500 Internal Server Error" -Status 500 } catch {}
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
