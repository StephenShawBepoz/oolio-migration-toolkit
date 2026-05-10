# Launch.ps1 - Oolio Migration Toolkit entry point
# Right-click and choose "Run as Administrator"

# 1. Elevation check - relaunch elevated if not running as admin
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 2. Set execution policy for this process only
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$toolkitRoot = $PSScriptRoot
$serverScript = Join-Path $toolkitRoot "server\server.ps1"

if (-not (Test-Path $serverScript)) {
    Write-Host "ERROR: server.ps1 not found at $serverScript" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Pick the first port from the candidate list that we can bind to. Some sites
# already have 8080 taken (Tomcat, Jenkins, dev tools), so we walk a short list
# rather than failing silently when the default is in use.
function Test-PortFree {
    param([int]$Port)
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $tcp.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($tcp) { try { $tcp.Stop() } catch {} }
    }
}

$candidatePorts = @(8080, 8081, 8082, 8083, 8084)
$chosenPort = $null
foreach ($p in $candidatePorts) {
    if (Test-PortFree -Port $p) { $chosenPort = $p; break }
}
if (-not $chosenPort) {
    Write-Host "Could not find a free port in $($candidatePorts -join ', '). Close anything using these ports and retry." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Oolio Migration Toolkit" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
if ($chosenPort -ne 8080) {
    Write-Host "Default port 8080 is in use. Falling back to $chosenPort." -ForegroundColor Yellow
}
Write-Host "Starting local server on http://localhost:$chosenPort..."

# 3. Start server as background job (pass chosen port through)
$job = Start-Job -FilePath $serverScript -ArgumentList $toolkitRoot, $chosenPort

# 4. Poll /ping until ready (up to ~5 seconds)
$ready = $false
for ($i = 0; $i -lt 10; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$chosenPort/ping" -UseBasicParsing -TimeoutSec 1
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
}

if (-not $ready) {
    Write-Host "Server failed to start within 5 seconds." -ForegroundColor Red
    Write-Host "Job output:" -ForegroundColor Yellow
    Receive-Job -Job $job
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -ErrorAction SilentlyContinue
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Server ready." -ForegroundColor Green

# 5. Open default browser
Start-Process "http://localhost:$chosenPort"

# 6. Hold the window open
Write-Host ""
Write-Host "Oolio Migration Toolkit is running." -ForegroundColor Green
Write-Host "Close this window to stop the server." -ForegroundColor Yellow
Write-Host ""

# Stream job output to console while running
try {
    while ($job.State -eq 'Running') {
        Receive-Job -Job $job
        Start-Sleep -Seconds 1
    }
    Receive-Job -Job $job
} finally {
    # 7. Cleanup on close
    Write-Host "Stopping server..." -ForegroundColor Yellow
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -ErrorAction SilentlyContinue
    Write-Host "Server stopped."
}
