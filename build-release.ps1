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

.PARAMETER IncludeInstallers
    Bundle any .exe sitting in installers/ into the zip. Off by default.

    The Oolio POS native installer is ~35 MB and is not committed to git, so the
    standard build ships a ~120 KB zip with an empty installers/ folder and its
    README. Technicians running a Windows-app deployment drop the .exe in on the
    terminal. Use this switch to build a self-contained zip for USB / offline use.

.PARAMETER IncludeTools
    Also ship tools/ (Internet-Check). Off by default - Internet-Check is a
    standalone diagnostic with its own bootstrapper and is not needed by Launch.ps1.

.PARAMETER OutDir
    Where to write the zip. Defaults to dist/ beside this script.

.EXAMPLE
    ./build-release.ps1
    Standard release build. ~120 KB.

.EXAMPLE
    ./build-release.ps1 -IncludeInstallers
    Self-contained build for USB / offline deployment. ~35 MB.
#>
[CmdletBinding()]
param(
    [switch]$IncludeInstallers,
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
#   installers/*.exe - see -IncludeInstallers.
#
# installers/ itself always ships (folder + README) so the path exists on the
# terminal for a technician to drop the POS installer into. scripts/oolio.ps1
# reads $toolkitRoot\installers\POS-*installer.exe at run time.
# ---------------------------------------------------------------------------
$runtimeFiles = @(
    'Launch.ps1'
)
$runtimeDirs = @(
    'scripts',
    'server',
    'ui',
    'assets',
    'installers'
)
if ($IncludeTools) { $runtimeDirs += 'tools' }

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

# Asking for installers you do not have is a build error, not a silent no-op.
if ($IncludeInstallers) {
    $exes = @(Get-ChildItem -Path (Join-Path $repoRoot 'installers') -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    if ($exes.Count -eq 0) {
        Write-Host "ERROR: -IncludeInstallers was specified but installers/ contains no .exe." -ForegroundColor Red
        Write-Host "       Place the Oolio POS installer there, or drop the switch." -ForegroundColor Yellow
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

# Drop bundled installers unless explicitly asked for. Done after the copy so a
# developer's local .exe never sneaks into a standard release build.
if (-not $IncludeInstallers) {
    $dropped = @(Get-ChildItem -Path (Join-Path $stageDir 'installers') -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    foreach ($e in $dropped) {
        Remove-Item -Path $e.FullName -Force -ErrorAction SilentlyContinue
        Write-Host ("  - installers/{0} (excluded; use -IncludeInstallers to bundle)" -f $e.Name) -ForegroundColor DarkGray
    }
}

# --- Size breakdown, so a large zip is never a surprise ---
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

if ($IncludeInstallers) {
    Write-Host ''
    Write-Host 'Built WITH the native Oolio POS installer bundled (-IncludeInstallers).' -ForegroundColor Yellow
    Write-Host 'Use this for USB / offline deployment, not for the public release asset.' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host 'Windows-app deployments need the POS installer dropped into installers\ on' -ForegroundColor DarkGray
    Write-Host 'the terminal. Chrome deployments need nothing further.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Next: GitHub > Releases > Draft a new release' -ForegroundColor Cyan
Write-Host '      Tag the release, attach this file as "OolioMigration.zip", publish.' -ForegroundColor Cyan
Write-Host '      The bootstrap one-liner picks it up immediately - no URL change needed.' -ForegroundColor Cyan
Write-Host ''
