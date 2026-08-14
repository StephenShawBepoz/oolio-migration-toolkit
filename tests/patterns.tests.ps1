# patterns.tests.ps1 - guards the clean-desktop matching patterns.
#
# Run:  pwsh -NoProfile -File tests/patterns.tests.ps1   (or powershell.exe on Windows)
# Exits 1 on any failure. No framework needed - these patterns delete files on
# venue terminals, so the must-keep list is the contract.

$ErrorActionPreference = 'Stop'

# Keep in sync with Invoke-WindowsCleanDesktop in scripts/windows.ps1.
$windowsPs1 = Join-Path $PSScriptRoot '..\scripts\windows.ps1'
$src = Get-Content $windowsPs1 -Raw
if ($src -match "(?m)^\s*\`$namePattern\s*=\s*'([^']+)'") { $namePattern = $Matches[1] }
else { Write-Host "FAIL: could not extract namePattern from windows.ps1"; exit 1 }
if ($src -match "(?m)^\s*\`$targetPattern\s*=\s*'([^']+)'") { $targetPattern = $Matches[1] }
else { Write-Host "FAIL: could not extract targetPattern from windows.ps1"; exit 1 }

Write-Host "namePattern:   $namePattern"
Write-Host "targetPattern: $targetPattern"
Write-Host ""

$fail = 0

# --- Names that MUST be removed (Bepoz's own shortcuts) ---
$mustDelete = @(
    'Bepoz Backoffice.lnk', 'Bepoz Till.lnk', 'Paz.lnk', 'Paz - Shortcut.lnk',
    'TillPaz.lnk', 'BackOffice.lnk', 'Back Office.lnk', 'backoffice-legacy.lnk'
)
# --- Names that must NEVER be removed (real venue shortcuts) ---
$mustKeep = @(
    'Topaz Signature Pad.lnk', 'Pazzo Pizza Menu.pdf.lnk', 'La Paz Reports.lnk',
    'Espazio.url', 'Oolio POS.lnk', 'Oolio CDS.lnk', 'Chrome.lnk',
    'Backorder Report.lnk', 'PazzleTime.lnk', 'TeamViewer.lnk'
)
foreach ($n in $mustDelete) {
    if ($n -notmatch $namePattern) { Write-Host "FAIL should-delete missed: $n"; $fail++ }
}
foreach ($n in $mustKeep) {
    if ($n -match $namePattern) { Write-Host "FAIL should-keep would be DELETED: $n"; $fail++ }
}

# --- Shortcut targets: only real C:\...\Bepoz\... paths may match ---
$targetDelete = @('C:\Bepoz\Till\TillPaz.exe', 'C:\Bepoz\BackOffice.exe', 'D:\Bepoz\x.exe', 'C:\Bepoz')
$targetKeep   = @('C:\BepozArchive\tool.exe', 'C:\Program Files\Topaz\sigpad.exe',
                  'C:\Oolio\Assets\pos-icon.ico', 'C:\Program Files\Google\Chrome\Application\chrome.exe')
foreach ($t in $targetDelete) {
    if ($t -notmatch $targetPattern) { Write-Host "FAIL target should-delete missed: $t"; $fail++ }
}
foreach ($t in $targetKeep) {
    if ($t -match $targetPattern) { Write-Host "FAIL target should-keep would be DELETED: $t"; $fail++ }
}

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "$fail failure(s)." -ForegroundColor Red
    exit 1
}
Write-Host "All pattern tests pass ($($mustDelete.Count + $mustKeep.Count) names, $($targetDelete.Count + $targetKeep.Count) targets)." -ForegroundColor Green
