# build-release.ps1 - packages OolioMigration.zip for a GitHub release
#
# Run from the repo root:
#     .\build-release.ps1
#
# Produces .\dist\OolioMigration.zip containing only what the toolkit needs at
# run time on a terminal. Upload that file as the release asset - bootstrap.ps1
# fetches it by the fixed name OolioMigration.zip.

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$distDir  = Join-Path $repoRoot 'dist'
$stageDir = Join-Path $distDir 'OolioMigration'
$zipPath  = Join-Path $distDir 'OolioMigration.zip'

# What ships. Everything else is deliberately left out.
$includeFiles = @(
    'Launch.ps1'
)
$includeDirs = @(
    'scripts',
    'server',
    'ui',
    'assets'
)

# Excluded on purpose:
#   bootstrap.ps1 - the remote installer. It is fetched raw from GitHub before
#                   the zip is ever downloaded, so shipping a copy inside the zip
#                   is dead weight and gives techs a second, stale copy to run.
#   claude.md / OVERVIEW.md / README.md / screenshots - documentation, not runtime.
#   progress.json - per-terminal state, generated on first run.

Write-Host ""
Write-Host "Building OolioMigration.zip..." -ForegroundColor Cyan
Write-Host ""

if (Test-Path $distDir) { Remove-Item -Path $distDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

foreach ($f in $includeFiles) {
    $src = Join-Path $repoRoot $f
    if (-not (Test-Path $src)) { throw "Required file missing: $f" }
    Copy-Item -Path $src -Destination $stageDir -Force
    Write-Host "  + $f"
}

foreach ($d in $includeDirs) {
    $src = Join-Path $repoRoot $d
    if (-not (Test-Path $src)) { throw "Required folder missing: $d" }
    Copy-Item -Path $src -Destination $stageDir -Recurse -Force
    Write-Host "  + $d\"
}

# Drop anything that slipped in via a folder copy.
Get-ChildItem -Path $stageDir -Recurse -Include 'progress.json', '*.log' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stageDir, $zipPath)
Remove-Item -Path $stageDir -Recurse -Force

$sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Host ""
Write-Host "Built: $zipPath ($sizeMB MB)" -ForegroundColor Green
Write-Host "Upload this file as the 'OolioMigration.zip' asset on the GitHub release." -ForegroundColor Yellow
Write-Host ""
