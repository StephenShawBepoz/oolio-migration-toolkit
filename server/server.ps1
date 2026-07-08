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
            "check-join"       = "pending"
            "verify-autologon" = "pending"
            "enable-firewall"  = "pending"
            "active-hours"     = "pending"
            "harden-pos"       = "pending"
            "touch-pos"            = "pending"
            "disable-multitouch"   = "pending"
            "power-plan"           = "pending"
            "disable-distractions" = "pending"
            "locale-time"          = "pending"
            "check-ip"         = "pending"
            "switch-dhcp"      = "pending"
            "rename-device"    = "pending"
            "clean-desktop"    = "pending"
            "set-wallpaper"    = "pending"
        }
        dependencies = @{
            "check-chrome"      = "pending"
            "check-webview2"    = "pending"
            "teamviewer"        = "pending"
            "printer-utilities" = "pending"
        }
        oolio = @{
            "deployment-config"  = "pending"
            "create-folders"     = "pending"
            "install-pos-app"    = "pending"
            "install-pos-chrome" = "pending"
            "install-cds-chrome" = "pending"
            "install-kds-chrome" = "pending"
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

# Atomic JSON write: write to .tmp then Move-Item -Force so a crash mid-write
# never leaves progress.json half-written.
function Save-AtomicJson {
    param([string]$Path, [string]$Json)
    $tmp = "$Path.tmp"
    Set-Content -Path $tmp -Value $Json -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

if (-not (Test-Path $progressPath)) {
    Save-AtomicJson -Path $progressPath -Json (Get-DefaultProgress | ConvertTo-Json -Depth 5)
}

# ----- CSRF token -----
# Mint a random per-session token at startup. Inject into index.html and require
# it on POST /progress and GET /run. Mitigates same-browser cross-origin abuse
# (any page open in the same browser as the toolkit can otherwise hit localhost).
$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$script:CsrfToken = ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLower()

# ----- Per-step locking -----
# Stop two browser tabs (or a double-click) launching the same step twice. Keyed
# by "moduleId/stepId". Cleared in the streaming function's finally block.
$script:ActiveSteps = @{}

# ----- Pending secret inputs -----
# Credentials stashed by POST /input just before a /run. EventSource is GET-only
# and URLs persist in browser history on the terminal, so secrets must never
# ride in the /run query string. Keyed by "moduleId/stepId"; single-use - the
# streaming function consumes and removes the entry.
$script:PendingSecrets = @{}

# ----- Manifest validator -----
# Catch UI/router/module drift at boot. For every router entry, confirm the
# referenced function actually exists in the matching module script and that
# Get-DefaultProgress covers it. Also: full AST syntax check of every module
# script (a typo otherwise only surfaces when a tech runs the step mid-
# migration), and a reverse check that every runnable step declared in app.js
# has a router mapping. Returns the issue list; the caller prints it and
# exposes it via GET /health so the UI can surface a banner.
function Test-StepManifest {
    param([string]$ScriptsPath, [string]$UiPath)
    $issues = @()
    $defaults = Get-DefaultProgress
    $scriptMap = @{
        "bepoz"        = "bepoz.ps1"
        "windows"      = "windows.ps1"
        "dependencies" = "dependencies.ps1"
        "oolio"        = "oolio.ps1"
    }
    # Pull the router table by inspecting the function source.
    $routerSrc = (Get-Command Get-StepFunctionName).ScriptBlock.ToString()
    $allRouterSteps = @()
    foreach ($mod in $scriptMap.Keys) {
        $modScript = Join-Path $ScriptsPath $scriptMap[$mod]
        if (-not (Test-Path $modScript)) { $issues += "Missing module script: $modScript"; continue }

        # AST parse - catches syntax errors before a technician does.
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($modScript, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $pe = $parseErrors[0]
            $issues += "Syntax error in $($scriptMap[$mod]) line $($pe.Extent.StartLineNumber): $($pe.Message)"
            continue
        }

        $modContent = Get-Content -Path $modScript -Raw
        # Crude but effective: extract function names defined in the module.
        $defined = [regex]::Matches($modContent, '(?m)^\s*function\s+([A-Za-z][A-Za-z0-9_-]+)') | ForEach-Object { $_.Groups[1].Value }
        # Each module's router block looks like: "module" = @{ "step" = "Func" ... }
        $blockMatch = [regex]::Match($routerSrc, "`"$mod`"\s*=\s*@\{([^}]*)\}", 'Singleline')
        if (-not $blockMatch.Success) { $issues += "Router has no block for module '$mod'"; continue }
        $stepPairs = [regex]::Matches($blockMatch.Groups[1].Value, '"([^"]+)"\s*=\s*"([^"]+)"')
        foreach ($m in $stepPairs) {
            $stepId = $m.Groups[1].Value
            $func   = $m.Groups[2].Value
            $allRouterSteps += $stepId
            if ($defined -notcontains $func) {
                $issues += "Router maps $mod/$stepId -> $func but $func is not defined in $($scriptMap[$mod])"
            }
            if (-not $defaults[$mod].ContainsKey($stepId)) {
                $issues += "Router maps $mod/$stepId but Get-DefaultProgress has no entry for it"
            }
        }
    }

    # Reverse check: every runnable step the UI declares must have a router
    # mapping, or the Run button 404s at click time. Steps flagged configStep
    # or linksOnly never execute PowerShell, so they're exempt. Relies on each
    # step definition opening on a single line (current app.js convention).
    $appJsPath = Join-Path $UiPath "app.js"
    if (Test-Path $appJsPath) {
        foreach ($line in (Get-Content -Path $appJsPath)) {
            if ($line -notmatch "title:") { continue }
            if ($line -match "configStep:\s*true" -or $line -match "linksOnly:\s*true") { continue }
            if ($line -match "id:\s*'([a-z0-9-]+)'") {
                $sid = $matches[1]
                if ($allRouterSteps -notcontains $sid) {
                    $issues += "app.js declares runnable step '$sid' but the router has no mapping for it"
                }
            }
        }
    }

    return $issues
}
$script:ManifestIssues = @(Test-StepManifest -ScriptsPath $scriptsPath -UiPath $uiPath)
if ($script:ManifestIssues.Count -gt 0) {
    Write-Output "==== STEP MANIFEST ISSUES ===="
    foreach ($i in $script:ManifestIssues) { Write-Output "  $i" }
    Write-Output "=============================="
} else {
    Write-Output "Step manifest OK (4 modules validated, scripts parsed, UI cross-checked)."
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
            Save-AtomicJson -Path $Path -Json ($obj | ConvertTo-Json -Depth 5)
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
    # Returns $true on success, $false if the client has disconnected. Callers use
    # the return value to detect closed-tab sessions and kill the running child.
    param($Response, [string]$Data)
    $payload = ""
    foreach ($line in ($Data -split "`r?`n")) {
        $payload += "data: $line`n"
    }
    $payload += "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Response.OutputStream.Flush()
        return $true
    } catch {
        return $false
    }
}

function Invoke-StepStreaming {
    param($Response, [string]$ModuleId, [string]$StepId, [hashtable]$Params)

    # Initialised before the try so the finally block can always reference them,
    # even if an exception fires before the lock is taken.
    $stepKey  = "$ModuleId/$StepId"
    $lockHeld = $false

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

        # Per-step locking: refuse a second concurrent run of the same step.
        if ($script:ActiveSteps.ContainsKey($stepKey)) {
            $null = Send-SSE -Response $Response -Data "__ERROR__: Step '$stepKey' is already running in another browser tab. Wait for it to finish or close the other tab."
            $null = Send-SSE -Response $Response -Data "__DONE__"
            return
        }
        $script:ActiveSteps[$stepKey] = $true
        $lockHeld = $true

        function Quote-PSLiteral($s) { if ($null -eq $s) { return "''" }; return "'" + ($s -replace "'", "''") + "'" }

        $value = $Params["value"]

        # Build a child-PowerShell command. Non-secret args go on the command
        # line; secrets (verify-autologon credentials) go through environment
        # variables so they never appear in Process Explorer, Sysmon, or ETW.
        $argSegment = ""
        $childEnv = @{}
        if ($StepId -eq "rename-device") {
            $argSegment = " -terminalName " + (Quote-PSLiteral $value)
        } elseif ($StepId -eq "set-wallpaper") {
            $argSegment = " -toolkitRoot " + (Quote-PSLiteral $ToolkitRoot)
        } elseif ($StepId -eq "install-pos-app") {
            $argSegment = " -toolkitRoot " + (Quote-PSLiteral $ToolkitRoot)
        } elseif ($StepId -eq "verify-autologon") {
            # Credentials reach the child via ProcessStartInfo environment
            # variables, so they never touch the parent's own environment, the
            # child's command line, or any process-monitoring tooling. Prefer
            # the POST /input stash (kept out of the /run URL and browser
            # history); fall back to query params for backward compatibility.
            $stash = $script:PendingSecrets[$stepKey]
            if ($stash) {
                $childEnv["OOLIO_AL_USERNAME"] = [string]$stash.username
                $childEnv["OOLIO_AL_PASSWORD"] = [string]$stash.password
                $childEnv["OOLIO_AL_DOMAIN"]   = [string]$stash.domain
                $script:PendingSecrets.Remove($stepKey)
            } else {
                $childEnv["OOLIO_AL_USERNAME"] = [string]$Params["username"]
                $childEnv["OOLIO_AL_PASSWORD"] = [string]$Params["password"]
                $childEnv["OOLIO_AL_DOMAIN"]   = [string]$Params["domain"]
            }
        } elseif ($StepId -eq "active-hours") {
            $argSegment = " -updateHour " + (Quote-PSLiteral $value)
        } elseif ($StepId -eq "locale-time") {
            $argSegment = " -timeZone " + (Quote-PSLiteral $value)
        }

        $command = ". '$sharedScript'; . '$moduleScriptPath'; $functionName$argSegment"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$command`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($k in $childEnv.Keys) {
            $psi.EnvironmentVariables[$k] = $childEnv[$k]
        }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()

        Write-SessionLog ""
        Write-SessionLog ("--- {0} :: {1}/{2} ---" -f (Get-Date -Format 'HH:mm:ss'), $ModuleId, $StepId)

        # Stream stdout line by line, teeing each line to the session log.
        # __PROGRESS__: lines are UI-only ephemera (one JSON line per second per
        # long-running step) - skip them in the log file to keep it readable.
        # If Send-SSE reports the client has disconnected, kill the child so a
        # closed-tab session does not keep mutating the terminal.
        $clientGone = $false
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if ($null -ne $line) {
                if (-not $clientGone) {
                    $ok = Send-SSE -Response $Response -Data $line
                    if (-not $ok) {
                        $clientGone = $true
                        Write-SessionLog "[client-disconnected] killing child step process"
                        try { $proc.Kill() } catch {}
                        break
                    }
                }
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
        if ($lockHeld -and $stepKey) { $script:ActiveSteps.Remove($stepKey) }
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
                '^GET /health$' {
                    # Boot-time validator results, machine-readable. The UI
                    # shows a banner on the home view when issues is non-empty.
                    $payload = @{
                        status = $(if ($script:ManifestIssues.Count -eq 0) { "ok" } else { "issues" })
                        issues = @($script:ManifestIssues)
                    } | ConvertTo-Json -Depth 3
                    Write-TextResponse -Response $response -Body $payload -ContentType "application/json; charset=utf-8"
                    break
                }
                '^POST /input$' {
                    # Stash secret step inputs ahead of a /run so they never
                    # appear in the /run URL. CSRF-protected like POST /progress.
                    $hdrToken = $request.Headers["X-Oolio-Token"]
                    if ($hdrToken -ne $script:CsrfToken) {
                        Write-TextResponse -Response $response -Body '{"status":"error","message":"csrf"}' -ContentType "application/json" -Status 403
                        break
                    }
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                    try {
                        $obj = $body | ConvertFrom-Json
                        if ($obj.module -and $obj.step -and $obj.fields) {
                            $script:PendingSecrets["$($obj.module)/$($obj.step)"] = $obj.fields
                            Write-TextResponse -Response $response -Body '{"status":"ok"}' -ContentType "application/json"
                        } else {
                            Write-TextResponse -Response $response -Body '{"status":"error","message":"module, step, and fields are required"}' -ContentType "application/json" -Status 400
                        }
                    } catch {
                        Write-TextResponse -Response $response -Body '{"status":"error","message":"invalid json"}' -ContentType "application/json" -Status 400
                    }
                    break
                }
                '^GET /$' {
                    # Inject the per-session CSRF token into index.html so app.js
                    # can read it from a meta tag and attach it to subsequent
                    # POST /progress and GET /run calls.
                    $indexPath = Join-Path $uiPath "index.html"
                    if (-not (Test-Path $indexPath)) {
                        Write-TextResponse -Response $response -Body "404 Not Found" -Status 404
                    } else {
                        $html = Get-Content -Path $indexPath -Raw -Encoding UTF8
                        $meta = "<meta name=`"oolio-token`" content=`"$($script:CsrfToken)`">"
                        if ($html -match '<meta name="oolio-token"') {
                            $html = [regex]::Replace($html, '<meta name="oolio-token"[^>]*>', $meta)
                        } else {
                            $html = $html -replace '(?i)</head>', "    $meta`r`n</head>"
                        }
                        Write-TextResponse -Response $response -Body $html -ContentType "text/html; charset=utf-8"
                    }
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
                        Save-AtomicJson -Path $progressPath -Json (Get-DefaultProgress | ConvertTo-Json -Depth 5)
                    }
                    $body = Get-Content -Path $progressPath -Raw -Encoding UTF8
                    Write-TextResponse -Response $response -Body $body -ContentType "application/json; charset=utf-8"
                    break
                }
                '^POST /progress$' {
                    # CSRF: header check before any side-effecting work.
                    $hdrToken = $request.Headers["X-Oolio-Token"]
                    if ($hdrToken -ne $script:CsrfToken) {
                        Write-TextResponse -Response $response -Body '{"status":"error","message":"csrf"}' -ContentType "application/json" -Status 403
                        break
                    }
                    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                    try {
                        $null = $body | ConvertFrom-Json
                        Save-AtomicJson -Path $progressPath -Json $body
                        Write-TextResponse -Response $response -Body '{"status":"ok"}' -ContentType "application/json"
                    } catch {
                        Write-TextResponse -Response $response -Body '{"status":"error","message":"invalid json"}' -ContentType "application/json" -Status 400
                    }
                    break
                }
                '^GET /run$' {
                    # CSRF: token may come via header (EventSource cannot set
                    # headers) or query string. Both are accepted.
                    $hdrToken = $request.Headers["X-Oolio-Token"]
                    $qToken   = Get-QueryValue -Query $request.Url.Query -Key "t"
                    if (($hdrToken -ne $script:CsrfToken) -and ($qToken -ne $script:CsrfToken)) {
                        Write-TextResponse -Response $response -Body "403 Forbidden" -Status 403
                        break
                    }
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
