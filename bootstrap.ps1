# bootstrap.ps1 - Oolio Migration Toolkit remote bootstrapper
#
# Paste-and-run via ScreenConnect (or any remote shell) on a Windows POS terminal.
# Downloads the latest release zip, extracts to C:\OolioMigration\, and launches
# the toolkit elevated. Internet is only required at this moment - the toolkit
# itself runs offline once unpacked.
#
# Usage:
#   Either paste this whole file into a ScreenConnect command, or run the
#   one-liner below from any elevated PowerShell prompt:
#
#     iwr https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/bootstrap.ps1 -UseBasicParsing | iex

$ErrorActionPreference = 'Stop'

$repo        = 'StephenShawBepoz/oolio-migration-toolkit'
$zipUrl      = "https://github.com/$repo/releases/latest/download/OolioMigration.zip"
$installRoot = 'C:\OolioMigration'
$tempZip     = Join-Path $env:TEMP 'OolioMigration.zip'

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Oolio Migration Toolkit - bootstrapper" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Source:      $zipUrl"
Write-Host "Install dir: $installRoot"
Write-Host ""

# Force TLS 1.2 for older Windows builds
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (Test-Path $installRoot) {
    Write-Host "Existing $installRoot found. Removing before fresh install..." -ForegroundColor Yellow
    Remove-Item -Path $installRoot -Recurse -Force
}

Write-Host "Downloading release zip..."
Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing

Write-Host "Extracting to $installRoot..."
Expand-Archive -Path $tempZip -DestinationPath $installRoot -Force
Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue

# If the zip contained a wrapping OolioMigration\ folder, lift its contents up.
$inner = Join-Path $installRoot 'OolioMigration'
if (Test-Path $inner) {
    Get-ChildItem -Path $inner -Force | Move-Item -Destination $installRoot -Force
    Remove-Item -Path $inner -Recurse -Force
}

$launch = Join-Path $installRoot 'Launch.ps1'
if (-not (Test-Path $launch)) {
    Write-Host "ERROR: Launch.ps1 not found after extraction." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Bootstrap complete. Launching toolkit..." -ForegroundColor Green
Write-Host "(A new elevated PowerShell window will open and the browser will follow.)"
Write-Host ""

Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$launch`""
