# internet-check-bootstrap.ps1 - Internet-Check remote bootstrapper
#
# Paste-and-run via ScreenConnect (or any PowerShell prompt) on a Windows POS
# terminal. Downloads the latest Internet-Check.ps1, drops it in C:\OolioTools\
# InternetCheck, prompts for an optional venue label, and runs it live in this
# window. Press Ctrl+C to stop and save a summary.
#
# Usage:
#   Either paste this whole file in, or run the one-liner below from a
#   PowerShell prompt (elevation recommended so all event logs are readable):
#
#     iwr https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/tools/internet-check-bootstrap.ps1 -UseBasicParsing | iex

$ErrorActionPreference = 'Stop'

# Bypass execution policy for this process only - the bootstrap itself ran via
# iex (which the policy doesn't gate), but invoking the downloaded .ps1 file
# does, so we relax it here. Scope=Process means we don't change machine policy.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

$rawUrl      = 'https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/tools/Internet-Check.ps1'
$installRoot = 'C:\OolioTools\InternetCheck'
$scriptPath  = Join-Path $installRoot 'Internet-Check.ps1'
$logFolder   = Join-Path $installRoot 'logs'

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Internet Check - 24h connectivity monitor" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Source:      $rawUrl"
Write-Host "Install dir: $installRoot"
Write-Host "Logs:        $logFolder"
Write-Host ""

# Force TLS 1.2 for older Windows builds
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Elevation hint (not required, but WLAN/DHCP event log reads work better as admin)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Note: not running elevated. WLAN/DHCP event log capture may be limited." -ForegroundColor Yellow
    Write-Host "      Probes and CSV output will still work normally." -ForegroundColor Yellow
    Write-Host ""
}

# Ensure folders exist
foreach ($p in @($installRoot, $logFolder)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# Download script (overwrites any previous copy so we always run the latest)
Write-Host "Downloading Internet-Check.ps1..."
Invoke-WebRequest -Uri $rawUrl -OutFile $scriptPath -UseBasicParsing
Write-Host "Saved to: $scriptPath" -ForegroundColor Green
Write-Host ""

# Optional venue label so support can tell multi-site runs apart
$venue = Read-Host "Venue label (optional - press Enter to skip)"
$intervalRaw = Read-Host "Probe interval in seconds (default: 10)"
$interval = 10
if ($intervalRaw -and [int]::TryParse($intervalRaw, [ref]$interval)) {
    if ($interval -lt 5)   { $interval = 5 }
    if ($interval -gt 300) { $interval = 300 }
} else {
    $interval = 10
}

Write-Host ""
Write-Host "Logs will be saved to: $logFolder" -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop and save a summary." -ForegroundColor Yellow
Write-Host ""

# Run in the same window so the tech can watch it live and Ctrl+C cleanly.
# IMPORTANT: we do NOT execute the saved .ps1 as a file - on managed terminals
# Group Policy can lock execution policy at MachinePolicy scope, which overrides
# even '-ExecutionPolicy Bypass'. Instead read the script's contents and run
# them as an inline scriptblock. The file-load policy check doesn't apply to
# script blocks created from strings, so this works regardless of GPO.
$scriptContent = Get-Content -Path $scriptPath -Raw -Encoding UTF8
$sb = [scriptblock]::Create($scriptContent)
& $sb -OutputFolder $logFolder -IntervalSeconds $interval -VenueLabel $venue
