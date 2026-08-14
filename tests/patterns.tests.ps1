# patterns.tests.ps1 - guards the clean-desktop matching contract.
#
# Run:  pwsh -NoProfile -File tests/patterns.tests.ps1   (or powershell.exe on Windows)
# Exits 1 on any failure. No framework needed - these patterns delete files on
# venue terminals, so the must-keep list is the contract.
#
# The deletion contract (mirrors Test-IsBepozShortcut in scripts/windows.ps1):
#   - only .lnk / .url files are ever candidates
#   - a DISTINCTIVE name ($strongPattern) deletes on its own
#   - otherwise a .lnk whose target/args point into C:\Bepoz ($targetPattern) deletes
#   - generic names ("Back Office") never delete without a Bepoz target

$ErrorActionPreference = 'Stop'

$windowsPs1 = Join-Path $PSScriptRoot '..\scripts\windows.ps1'
$src = Get-Content $windowsPs1 -Raw
if ($src -match "(?m)^\s*\`$strongPattern\s*=\s*'([^']+)'") { $strongPattern = $Matches[1] }
else { Write-Host "FAIL: could not extract strongPattern from windows.ps1"; exit 1 }
if ($src -match "(?m)^\s*\`$targetPattern\s*=\s*'([^']+)'") { $targetPattern = $Matches[1] }
else { Write-Host "FAIL: could not extract targetPattern from windows.ps1"; exit 1 }

Write-Host "strongPattern: $strongPattern"
Write-Host "targetPattern: $targetPattern"
Write-Host ""

# Re-implementation of the decision, kept in lockstep with Test-IsBepozShortcut.
function Test-Decision {
    param([string]$Name, [string]$Target = '')
    $ext = [System.IO.Path]::GetExtension($Name)
    if ($ext -ne '.lnk' -and $ext -ne '.url') { return $false }
    if ($Name -match $strongPattern) { return $true }
    if ($ext -ne '.lnk') { return $false }
    if ($Target -and ($Target -match $targetPattern)) { return $true }
    if ($Target -and ($Target -match $strongPattern)) { return $true }
    return $false
}

$fail = 0
function Assert-Deleted { param($Name, $Target = '')
    if (-not (Test-Decision -Name $Name -Target $Target)) {
        Write-Host "FAIL should-delete missed: $Name (target: $Target)"; $script:fail++
    }
}
function Assert-Kept { param($Name, $Target = '')
    if (Test-Decision -Name $Name -Target $Target) {
        Write-Host "FAIL should-keep would be DELETED: $Name (target: $Target)"; $script:fail++
    }
}

# --- Bepoz's own shortcuts: deleted ---
Assert-Deleted 'Bepoz Backoffice.lnk'
Assert-Deleted 'Bepoz Till.lnk'
Assert-Deleted 'Paz.lnk'
Assert-Deleted 'Paz - Shortcut.lnk'
Assert-Deleted 'TillPaz.lnk'
Assert-Deleted 'Bepoz.url'
# Renamed / generic-name Bepoz shortcuts: caught by their target
Assert-Deleted 'BackOffice.lnk'   'C:\Bepoz\BackOffice.exe'
Assert-Deleted 'Back Office.lnk'  'C:\Bepoz\BackOffice.exe'
Assert-Deleted 'Till.lnk'         'C:\Bepoz\Till\TillPaz.exe'
Assert-Deleted 'POS System.lnk'   'D:\Bepoz\x.exe'

# --- Venue property: never deleted ---
Assert-Kept 'Topaz Signature Pad.lnk'  'C:\Program Files\Topaz\sigpad.exe'
Assert-Kept 'Pazzo Pizza Menu.lnk'
Assert-Kept 'La Paz Reports.lnk'
Assert-Kept 'Espazio.url'
Assert-Kept 'Oolio POS.lnk'            'C:\Program Files\Google\Chrome\Application\chrome.exe'
Assert-Kept 'Oolio CDS.lnk'
Assert-Kept 'Chrome.lnk'
Assert-Kept 'TeamViewer.lnk'
Assert-Kept 'Backorder Report.lnk'
Assert-Kept 'PazzleTime.lnk'
# Generic names with NON-Bepoz targets: kept (the old code deleted these)
Assert-Kept 'MYOB Back Office.lnk'     'C:\MYOB\backoffice.exe'
Assert-Kept 'Back Office.lnk'          'C:\VenueTools\rosters.exe'
Assert-Kept 'BackOffice.lnk'
# Non-shortcut files: never candidates, whatever the name (the old code deleted these)
Assert-Kept 'Bepoz EOD Procedures.pdf'
Assert-Kept 'Back Office Roster.xlsx'
Assert-Kept 'paz notes.txt'
Assert-Kept 'Bepoz Backup.zip'
# Near-miss paths: kept
Assert-Kept 'Tool.lnk'                 'C:\BepozArchive\tool.exe'

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "$fail failure(s)." -ForegroundColor Red
    exit 1
}
Write-Host "All pattern tests pass." -ForegroundColor Green
