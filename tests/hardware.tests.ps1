# hardware.tests.ps1 - contract for the hardware suitability verdict.
#
# Run:  pwsh -NoProfile -File tests/hardware.tests.ps1   (or powershell.exe on Windows)
# Exits 1 on any failure. Guards the thresholds a technician's "wipe or replace?"
# decision hangs on - so the 4 GB floor can't silently drift.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\system.ps1')

$fail = 0
function Check {
    param($Name, $Verdict, $ExpectLevel, [string]$AdviceMustMatch)
    if ($Verdict.Level -ne $ExpectLevel) {
        Write-Host "FAIL [$Name]: expected $ExpectLevel, got $($Verdict.Level) - '$($Verdict.Summary)'"; $script:fail++
        return
    }
    if ($AdviceMustMatch) {
        $joined = ($Verdict.Advice -join ' ')
        if ($joined -notmatch $AdviceMustMatch) {
            Write-Host "FAIL [$Name]: advice did not mention /$AdviceMustMatch/ - got: $joined"; $script:fail++
            return
        }
    }
    Write-Host "ok   [$Name]: $($Verdict.Level)"
}

# 2 GB - unusable, must say replace, and must explicitly state a wipe will NOT help.
$v = Get-HardwareVerdict -RamGB 2 -FreeDiskGB 40
Check '2GB is FAIL' $v 'FAIL' 'Replace'
Check '2GB says wipe will not help' $v 'FAIL' 'NOT help'

# 4 GB - the user's line: usable but advise a wipe first, replacement if still slow.
$v = Get-HardwareVerdict -RamGB 4 -FreeDiskGB 40
Check '4GB is WARN' $v 'WARN' 'clean wipe'
Check '4GB mentions replace as durable fix' $v 'WARN' 'replace'

# 4 GB Surface Go - the known fleet, should be called out by name.
$v = Get-HardwareVerdict -RamGB 4 -FreeDiskGB 40 -Model 'Microsoft Corporation Surface Go'
Check '4GB Surface Go named' $v 'WARN' 'Surface Go'

# 8 GB with healthy disk - all clear.
$v = Get-HardwareVerdict -RamGB 8 -FreeDiskGB 80
Check '8GB is OK' $v 'OK'

# 16 GB - all clear.
$v = Get-HardwareVerdict -RamGB 16 -FreeDiskGB 200
Check '16GB is OK' $v 'OK'

# 8 GB but nearly-full disk - downgraded to WARN with a disk note.
$v = Get-HardwareVerdict -RamGB 8 -FreeDiskGB 5
Check '8GB low disk is WARN' $v 'WARN' 'free on the system drive'

# 8 GB on a spinning HDD - WARN with an SSD suggestion.
$v = Get-HardwareVerdict -RamGB 8 -FreeDiskGB 80 -IsRotationalDisk $true
Check '8GB HDD is WARN' $v 'WARN' 'SSD'

# Boundary: exactly at the 8 GB recommendation is OK, one under is WARN.
Check '7GB is WARN' (Get-HardwareVerdict -RamGB 7 -FreeDiskGB 80) 'WARN'
Check '8GB boundary OK' (Get-HardwareVerdict -RamGB 8 -FreeDiskGB 80) 'OK'

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "$fail failure(s)." -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All hardware verdict tests pass." -ForegroundColor Green
