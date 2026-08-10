<#
.SYNOPSIS
    Packages dist/OolioMigration.zip for a GitHub release.

.DESCRIPTION
    Stages only the files the toolkit needs at run time on a terminal, zips them,
    and prints the size breakdown plus a SHA-256 so you can confirm the asset you
    upload is the one you built.

    The release asset MUST be published under the name OolioMigration.zip -
    bootstrap.ps1 fetches that exact filename from releases/latest/download/.

    Runs on Windows PowerShell 5.1 and on PowerShell 7 (macOS / Linux).
    On a Mac you need pwsh:  brew install --cask powershell

.PARAMETER SkipInstallers
    Build without the bundled Oolio POS installer. Produces a ~120 KB zip instead
    of ~35 MB, but Module 4's "Install Oolio POS (native Windows app)" step will
    fail on the terminal unless the technician supplies the .exe by hand. Use for
    Chrome-only deployments or for testing.

.PARAMETER IncludeTools
    Also ship tools/ (Internet-Check). Off by default - Internet-Check is a
    standalone diagnostic with its own bootstrapper and is not needed by Launch.ps1.

.PARAMETER OutDir
    Where to write the zip. Defaults to dist/ beside this script.

.EXAMPLE
    ./build-release.ps1
    Full release build, matching what v1.5.1 shipped.

.EXAMPLE
    ./build-release.ps1 -SkipInstallers
    Lightweight build for testing the wizard without the 35 MB payload.
#>
[CmdletBinding()]
param(
    [switch]$SkipInstallers,
    [switch]$IncludeTools,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'dist' }
$stageDir = Join-Path $OutDir 'OolioMigration'
$zipPath  = Join-Path $OutDir 'OolioMigration.zip'

# ---------------------------------------------------------------------------
# What ships.
#
# Everything not listed here is deliberately left out:
#   bootstrap.ps1  - fetched raw from GitHub *before* the zip is ever downloaded,
#                    so a copy inside the archive is dead weight. Worse, it leaves
#                    a second, potentially stale bootstrapper on the terminal that
#                    a technician might run instead of the current one.
#   *.md, screenshots/ - documentation. Not needed at run time.
#   tools/         - Internet-Check is a standalone diagnostic (see -IncludeTools).
#   progress.json  - per-terminal state, generated on first run.
# ---------------------------------------------------------------------------
$runtimeFiles = @(
    'Launch.ps1'
)
$runtimeDirs = @(
    'scripts',
    'server',
    'ui',
    'assets'
)

# installers/ holds the native Oolio POS installer. scripts/oolio.ps1 reads
# $toolkitRoot\installers\POS-*installer.exe at run time, so this is load-bearing
# for Module 4's native-app step - not optional packaging.
if (-not $SkipInstallers) { $runtimeDirs += 'installers' }
if ($IncludeTools)        { $runtimeDirs += 'tools' }

Write-Host ''
Write-Host '===============================================' -ForegroundColor Cyan
Write-Host ' Oolio Migration Toolkit - release build' -ForegroundColor Cyan
Write-Host '===============================================' -ForegroundColor Cyan
Write-Host ''

# --- Context: which commit is this build from? Informational only. ---
try {
    $branch = (& git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null)
    $commit = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
    $dirty  = (& git -C $repoRoot status --porcelain 2>$null)
    if ($branch) {
        Write-Host ("Building from: {0} @ {1}" -f $branch, $commit)
        if ($branch -ne 'main') {
            Write-Host "  Note: not on main. Releases are normally cut from main." -ForegroundColor Yellow
        }
        if ($dirty) {
            Write-Host "  Note: working tree has uncommitted changes - they WILL be included." -ForegroundColor Yellow
        }
        Write-Host ''
    }
} catch {
    # git not available - not fatal, this is just context
}

# --- Validate before touching anything ---
$missing = @()
foreach ($f in $runtimeFiles) {
    if (-not (Test-Path (Join-Path $repoRoot $f))) { $missing += $f }
}
foreach ($d in $runtimeDirs) {
    if (-not (Test-Path (Join-Path $repoRoot $d))) { $missing += "$d/" }
}
if ($missing.Count -gt 0) {
    Write-Host "ERROR: required content is missing from $repoRoot" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# The native-app step needs an actual .exe, not just the folder.
if (-not $SkipInstallers) {
    $exes = @(Get-ChildItem -Path (Join-Path $repoRoot 'installers') -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    if ($exes.Count -eq 0) {
        Write-Host "ERROR: installers/ contains no .exe." -ForegroundColor Red
        Write-Host "       Module 4's native Oolio POS install step would fail on the terminal." -ForegroundColor Red
        Write-Host "       Add the installer, or build with -SkipInstallers if that is intended." -ForegroundColor Yellow
        exit 1
    }
}

# --- Stage ---
if (Test-Path $OutDir) { Remove-Item -Path $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

Write-Host 'Staging:'
foreach ($f in $runtimeFiles) {
    Copy-Item -Path (Join-Path $repoRoot $f) -Destination $stageDir -Force
    Write-Host "  + $f"
}
foreach ($d in $runtimeDirs) {
    Copy-Item -Path (Join-Path $repoRoot $d) -Destination $stageDir -Recurse -Force
    Write-Host "  + $d/"
}

# Strip anything that rode in on a folder copy.
Get-ChildItem -Path $stageDir -Recurse -File -Include 'progress.json', '*.log', '.DS_Store', 'Thumbs.db' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# --- Size breakdown, so a 35 MB zip is never a surprise ---
Write-Host ''
Write-Host 'Contents (uncompressed, largest first):'
$entries = Get-ChildItem -Path $stageDir -Force | ForEach-Object {
    if ($_.PSIsContainer) {
        $bytes = (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { $bytes = 0 }
        [pscustomobject]@{ Bytes = [double]$bytes; Label = $_.Name + '/' }
    } else {
        [pscustomobject]@{ Bytes = [double]$_.Length; Label = $_.Name }
    }
}
foreach ($e in ($entries | Sort-Object Bytes -Descending)) {
    Write-Host ('  {0,10:N1} KB  {1}' -f ($e.Bytes / 1KB), $e.Label)
}
$totalKB = ($entries | Measure-Object -Property Bytes -Sum).Sum / 1KB
Write-Host ('  {0,10:N1} KB  = total staged' -f $totalKB) -ForegroundColor DarkGray

# --- Zip ---
# PowerShell 7 has System.IO.Compression.ZipFile loaded; 5.1 needs the assembly.
if ($PSVersionTable.PSEdition -ne 'Core') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
[System.IO.Compression.ZipFile]::CreateFromDirectory($stageDir, $zipPath)
Remove-Item -Path $stageDir -Recurse -Force

$zipItem = Get-Item $zipPath
$sizeMB  = [math]::Round($zipItem.Length / 1MB, 2)
$sha     = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()

Write-Host ''
Write-Host "Built: $zipPath" -ForegroundColor Green
Write-Host ("Size:  {0} MB" -f $sizeMB) -ForegroundColor Green
Write-Host "SHA256: $sha" -ForegroundColor DarkGray

if ($SkipInstallers) {
    Write-Host ''
    Write-Host 'Built WITHOUT the native Oolio POS installer (-SkipInstallers).' -ForegroundColor Yellow
    Write-Host "Module 4's native-app step will fail unless the technician supplies the .exe." -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Next: GitHub > Releases > Draft a new release' -ForegroundColor Cyan
Write-Host '      Tag the release, attach this file as "OolioMigration.zip", publish.' -ForegroundColor Cyan
Write-Host '      The bootstrap one-liner picks it up immediately - no URL change needed.' -ForegroundColor Cyan
Write-Host ''
