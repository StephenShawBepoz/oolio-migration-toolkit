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

# Force TLS 1.2 for older Windows builds
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (Test-Path $installRoot) {
    Write-Host "Existing $installRoot found. Removing before fresh install..." -ForegroundColor Yellow
    Remove-Item -Path $installRoot -Recurse -Force
}

Write-Host "Downloading..."
Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing

Write-Host "Extracting to $installRoot..."
Expand-Archive -Path $tempZip -DestinationPath $installRoot -Force
Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue

# Both shapes wrap their contents in a single folder - the release zip may use
# OolioMigration\, and a GitHub branch archive always uses <repo>-<branch>\.
# Lift whichever is present so Launch.ps1 ends up at the install root.
$wrapper = @(Get-ChildItem -Path $installRoot -Directory -Force |
    Where-Object { Test-Path (Join-Path $_.FullName 'Launch.ps1') }) | Select-Object -First 1
if ($wrapper) {
    Get-ChildItem -Path $wrapper.FullName -Force | Move-Item -Destination $installRoot -Force
    Remove-Item -Path $wrapper.FullName -Recurse -Force
}

# A branch archive carries the whole repo. Strip everything build-release.ps1
# leaves out, so a main install and a release install produce an identical layout
# on the terminal - otherwise "works from the release, breaks from main" bugs creep
# in. bootstrap.ps1 in particular must go, so nobody later runs a stale copy from
# disk instead of the current one from GitHub. tools/ (Internet-Check) is excluded
# from both; it has its own bootstrapper.
if ($Source -eq 'main') {
    foreach ($junk in @('bootstrap.ps1', 'build-release.ps1', 'screenshots', 'tools', '.github', '.gitignore',
                        'README.md', 'OVERVIEW.md', 'CHANGELOG.md', 'claude.md')) {
        $p = Join-Path $installRoot $junk
        if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$launch = Join-Path $installRoot 'Launch.ps1'
if (-not (Test-Path $launch)) {
    Write-Host "ERROR: Launch.ps1 not found after extraction." -ForegroundColor Red
    Write-Host "       If you used the release source, the latest release may predate" -ForegroundColor Yellow
    Write-Host "       the current packaging. Retry with:" -ForegroundColor Yellow
    Write-Host "         `$env:OOLIO_SOURCE='main'" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "Bootstrap complete. Launching toolkit..." -ForegroundColor Green
Write-Host "(A new elevated PowerShell window will open and the browser will follow.)"
Write-Host ""

Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$launch`""
