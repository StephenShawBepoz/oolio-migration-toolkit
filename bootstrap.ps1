# bootstrap.ps1 - Oolio Migration Toolkit remote bootstrapper
#
# Paste-and-run via ScreenConnect (or any remote shell) on a Windows POS terminal.
# Downloads the toolkit, extracts to C:\OolioMigration\, and launches it elevated.
# Internet is only required at this moment - the toolkit runs offline once unpacked.
#
# Usage - run either one-liner from an ELEVATED PowerShell prompt:
#
#   Stable (latest published release):
#     iwr https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/bootstrap.ps1 -UseBasicParsing | iex
#
#   Latest code (current main branch, no release needed):
#     $env:OOLIO_SOURCE='main'; iwr https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/bootstrap.ps1 -UseBasicParsing | iex
#
# The env var is used rather than a parameter because `| iex` cannot pass
# arguments. -Source still works when the file is run directly.

# NOTE: deliberately no param() block. This script is normally run by piping its
# text into Invoke-Expression, and `| iex` evaluates a param() block in the
# CALLER's scope as a variable declaration - so a [ValidateSet] attribute is
# applied to an empty $Source and fails instantly with "The attribute cannot be
# added because variable Source with value would no longer be valid." Reading the
# environment variable, with a positional $args fallback for direct file
# execution, works identically in both invocation styles.

$ErrorActionPreference = 'Stop'

# Env var first (the only channel available under `| iex`), then a positional
# argument for `-File bootstrap.ps1 main`, then default to the published release.
$oolioSource = $env:OOLIO_SOURCE
if (-not $oolioSource -and $args.Count -ge 1) { $oolioSource = [string]$args[0] }
if (-not $oolioSource) { $oolioSource = 'release' }
$Source = $oolioSource.Trim().ToLower()

if (@('release', 'main') -notcontains $Source) {
    Write-Host "ERROR: source must be 'release' or 'main' (got '$Source')." -ForegroundColor Red
    Write-Host "       Set it with:  `$env:OOLIO_SOURCE='main'" -ForegroundColor Yellow
    exit 1
}

$repo        = 'StephenShawBepoz/oolio-migration-toolkit'
$installRoot = 'C:\OolioMigration'
$tempZip     = Join-Path $env:TEMP 'OolioMigration.zip'

if ($Source -eq 'main') {
    $zipUrl   = "https://github.com/$repo/archive/refs/heads/main.zip"
    $srcLabel = 'main branch (latest code, unreleased)'
} else {
    $zipUrl   = "https://github.com/$repo/releases/latest/download/OolioMigration.zip"
    $srcLabel = 'latest published release'
}

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Oolio Migration Toolkit - bootstrapper" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Source:      $srcLabel"
Write-Host "URL:         $zipUrl"
Write-Host "Install dir: $installRoot"
Write-Host ""
if ($Source -eq 'main') {
    Write-Host "Note: pulling straight from main - this is whatever was last pushed," -ForegroundColor Yellow
    Write-Host "      which may be ahead of the last tested release." -ForegroundColor Yellow
    Write-Host ""
}

# Force modern TLS for older Windows builds. Prefer 1.2+1.3 where the enum knows
# about 1.3 (newer .NET); fall back to 1.2 alone - same pattern as shared.ps1.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Refuse to reinstall over a running toolkit. Otherwise the old in-memory
# server keeps serving (stale server/router logic on the original port) while
# the new one falls back to the next port - two instances, mismatched code.
foreach ($probePort in 8080, 8081, 8082, 8083, 8084) {
    try {
        $ping = Invoke-WebRequest -Uri "http://localhost:$probePort/ping" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
        if ($ping.StatusCode -eq 200) {
            Write-Host "ERROR: a toolkit instance is already running on port $probePort." -ForegroundColor Red
            Write-Host "       Close the Oolio Migration Toolkit window on this terminal, then re-run." -ForegroundColor Yellow
            exit 1
        }
    } catch {}
}

# Download and stage into TEMP FIRST. Only once the new tree is validated do we
# touch the existing install - so a failed download or a truncated zip can never
# leave the terminal with no toolkit at all (the old delete-then-download order
# did exactly that).
Write-Host "Downloading..."
$stageRoot = Join-Path $env:TEMP ("OolioStage_" + [System.IO.Path]::GetRandomFileName())
try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
} catch {
    Write-Host "ERROR: download failed - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       The existing install (if any) is untouched. Check connectivity and re-run." -ForegroundColor Yellow
    exit 1
}

Write-Host "Staging..."
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
Expand-Archive -Path $tempZip -DestinationPath $stageRoot -Force
Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue

# Lift the wrapping folder (release zip uses OolioMigration\; a branch archive
# uses <repo>-<branch>\) so Launch.ps1 sits at the stage root.
$wrapper = @(Get-ChildItem -Path $stageRoot -Directory -Force |
    Where-Object { Test-Path (Join-Path $_.FullName 'Launch.ps1') }) | Select-Object -First 1
if ($wrapper) {
    Get-ChildItem -Path $wrapper.FullName -Force | Move-Item -Destination $stageRoot -Force
    Remove-Item -Path $wrapper.FullName -Recurse -Force
}

# A branch archive carries the whole repo. Strip everything build-release.ps1
# leaves out, so a main install and a release install produce an identical layout
# on the terminal. bootstrap.ps1 in particular must go, so nobody later runs a
# stale copy from disk instead of the current one from GitHub.
if ($Source -eq 'main') {
    foreach ($junk in @('bootstrap.ps1', 'build-release.ps1', 'screenshots', 'tools', '.github', '.gitignore',
                        'README.md', 'OVERVIEW.md', 'CHANGELOG.md', 'claude.md')) {
        $p = Join-Path $stageRoot $junk
        if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Validate the staged tree BEFORE destroying the existing install.
if (-not (Test-Path (Join-Path $stageRoot 'Launch.ps1'))) {
    Write-Host "ERROR: Launch.ps1 not found in the downloaded package - not installing." -ForegroundColor Red
    Write-Host "       The existing install (if any) is untouched. If you used the release" -ForegroundColor Yellow
    Write-Host "       source, retry with:  `$env:OOLIO_SOURCE='main'" -ForegroundColor Yellow
    Remove-Item -Path $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Swap into place. Preserve per-terminal state (progress.json) and any locally
# supplied installer across the reinstall - both are gitignored and absent from
# the package, so re-extraction cannot restore them, and losing progress.json
# would reset every step status and re-arm destructive steps already run.
# OOLIO_FRESH=1 forces a clean install that discards saved progress.
$preserve = @{}
if ($env:OOLIO_FRESH -ne '1' -and (Test-Path $installRoot)) {
    $progressSrc = Join-Path $installRoot 'progress.json'
    if (Test-Path $progressSrc) {
        $preserve['progress.json'] = Get-Content -Path $progressSrc -Raw -Encoding UTF8
        Write-Host "Preserving existing migration progress (set OOLIO_FRESH=1 to discard)." -ForegroundColor Cyan
    }
    $installerSrc = Join-Path $installRoot 'installers'
    if (Test-Path $installerSrc) {
        $exes = @(Get-ChildItem -Path $installerSrc -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        foreach ($e in $exes) { $preserve["installers\$($e.Name)"] = $e.FullName }
    }
}

if (Test-Path $installRoot) {
    Write-Host "Replacing existing $installRoot..." -ForegroundColor Yellow
    Remove-Item -Path $installRoot -Recurse -Force
}
$installParent = Split-Path $installRoot -Parent
if ($installParent -and -not (Test-Path $installParent)) {
    New-Item -ItemType Directory -Path $installParent -Force | Out-Null
}
Move-Item -Path $stageRoot -Destination $installRoot -Force

# Restore preserved files.
foreach ($rel in $preserve.Keys) {
    $dest = Join-Path $installRoot $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if ($rel -eq 'progress.json') {
        Set-Content -Path $dest -Value $preserve[$rel] -Encoding UTF8
    } else {
        Copy-Item -Path $preserve[$rel] -Destination $dest -Force -ErrorAction SilentlyContinue
    }
}

$launch = Join-Path $installRoot 'Launch.ps1'

Write-Host ""
Write-Host "Bootstrap complete. Launching toolkit..." -ForegroundColor Green
Write-Host "(A new elevated PowerShell window will open and the browser will follow.)"
Write-Host ""

Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$launch`""
