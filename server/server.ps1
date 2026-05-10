# server.ps1 - HTTP listener for Oolio Migration Toolkit
# Listens on http://localhost:8080/ and serves UI + executes module scripts

param([string]$ToolkitRoot)

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
            "read-registry"   = "pending"
            "stop-sql"        = "pending"
            "zip-data"        = "pending"
            "kill-processes"  = "pending"
            "clear-startup"   = "pending"
            "check-run-key"   = "pending"
            "delete-registry" = "pending"
            "uninstall"       = "pending"
        }
        windows = @{
            "verify-autologon" = "pending"
            "enable-firewall"  = "pending"
            "check-ip"         = "pending"
            "switch-dhcp"      = "pending"
            "rename-device"    = "pending"
            "clean-desktop"    = "pending"
            "set-wallpaper"    = "pending"
        }
        dependencies = @{
            "check-chrome"      = "pending"
            "check-webview2"    = "pending"
            "printer-utilities" = "pending"
        }
        oolio = @{
            "terminal-type"       = "pending"
            "create-folders"      = "pending"
            "install-pos-chrome"  = "pending"
            "install-pos-app"     = "pending"
            "install-cds-chrome"  = "pending"
            "install-cds-app"     = "pending"
            "install-kds-chrome"  = "pending"
            "set-startup"         = "pending"
            "final-restart"       = "pending"
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

# ----- HTTP Listener -----
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8080/")
$listener.Start()
Write-Output "Listening on http://localhost:8080/"

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
        } elseif ($StepId -eq "set-startup") {
            $argSegment = " -terminalType " + (Quote-PSLiteral $value)
        } elseif ($StepId -eq "verify-autologon") {
            $u = $Params["username"]; $p = $Params["password"]; $d = $Params["domain"]
            $argSegment = " -username " + (Quote-PSLiteral $u) + " -password " + (Quote-PSLiteral $p) + " -domain " + (Quote-PSLiteral $d)
        } elseif ($StepId -eq "uninstall") {
            # No argument needed - reads BackupPath from registry directly.
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

        # Stream stdout line by line
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if ($null -ne $line) { Send-SSE -Response $Response -Data $line }
        }

        # Drain stderr
        $errOutput = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        if ($errOutput -and $errOutput.Trim().Length -gt 0) {
            foreach ($eline in ($errOutput -split "`r?`n")) {
                if ($eline.Trim().Length -gt 0) {
                    Send-SSE -Response $Response -Data "[ERROR] $eline"
                }
            }
        }

        if ($proc.ExitCode -ne 0) {
            Send-SSE -Response $Response -Data "__ERROR__: Step exited with code $($proc.ExitCode)"
        }

        Send-SSE -Response $Response -Data "__DONE__"
    } catch {
        Send-SSE -Response $Response -Data "__ERROR__: $($_.Exception.Message)"
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
