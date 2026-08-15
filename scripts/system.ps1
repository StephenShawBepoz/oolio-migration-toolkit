# system.ps1 - Module 0: System / readiness checks (run before anything else)

# Pure verdict logic, separated from hardware probing so it can be unit-tested
# without a real machine (see tests/hardware.tests.ps1). Returns a verdict object:
#   Level   = 'OK' | 'WARN' | 'FAIL'
#   Summary = one-line headline
#   Advice  = @( ...lines... )  practical next steps for the technician
#
# Thresholds reflect running a single fullscreen Chrome app (POS / KDS / CDS)
# on Windows 10/11. The RAM floor is the decisive one: below it, no amount of
# cleanup makes the unit usable - a wipe clears cruft but cannot add memory.
function Get-HardwareVerdict {
    param(
        [double]$RamGB,
        [double]$FreeDiskGB,
        [string]$Model = "",
        [bool]$IsRotationalDisk = $false
    )

    $advice = @()

    # --- RAM: the decisive check ---
    if ($RamGB -lt 4) {
        return [pscustomobject]@{
            Level   = 'FAIL'
            Summary = "$RamGB GB RAM - below the 4 GB minimum. This unit is not suitable as an Oolio terminal."
            Advice  = @(
                "Replace this unit. A clean wipe will NOT help - it cannot add memory.",
                "If it must be used temporarily, expect it to be slow and unreliable under a browser POS/KDS."
            )
        }
    }

    if ($RamGB -lt 8) {
        # 4-7 GB: usable but below recommended. This is the classic old Surface Go
        # case - genuinely sluggish, but usually from accumulated cruft, not the RAM
        # alone. A wipe is the cheap first move; replacement is the durable fix.
        $advice += "4-7 GB is below the recommended 8 GB. If this unit is sluggish, do a clean wipe / reimage FIRST - that clears years of Windows Update backlog, background bloat, and a thrashing page file, which is the usual cause."
        $advice += "A wipe clears cruft but does not add RAM. If it is still slow after a clean reimage, replace the unit."
        if ($Model -match 'Surface Go') {
            $advice += "This is a Surface Go - the known-slow KDS fleet. On the 4 GB / 64 GB eMMC models, budget for replacement rather than repeated cleanups."
        }
        $verdictLevel = 'WARN'
        $summary = "$RamGB GB RAM - usable but below the recommended 8 GB."
    } else {
        $verdictLevel = 'OK'
        $summary = "$RamGB GB RAM - meets the recommended spec."
    }

    # --- Disk headroom (secondary) ---
    if ($FreeDiskGB -lt 10) {
        if ($verdictLevel -eq 'OK') { $verdictLevel = 'WARN' }
        $advice += "Only $FreeDiskGB GB free on the system drive. Low disk makes Windows Update and the browser cache thrash. Clear space, or wipe/reimage if the drive is chronically full (common on 64 GB eMMC)."
    }

    if ($IsRotationalDisk) {
        if ($verdictLevel -eq 'OK') { $verdictLevel = 'WARN' }
        $advice += "The system drive is a spinning HDD - a cheap SSD upgrade is the single biggest speed win on an older terminal."
    }

    if ($verdictLevel -eq 'OK' -and $advice.Count -eq 0) {
        $advice += "No action needed - this unit is suitable for an Oolio terminal."
    }

    return [pscustomobject]@{ Level = $verdictLevel; Summary = $summary; Advice = $advice }
}

function Invoke-SystemCheckHardware {
    Write-Section "Checking hardware suitability"

    # --- Gather ---
    $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    # Installed RAM. Win32_PhysicalMemory sums the actual modules (TotalPhysicalMemory
    # under-reports by the hardware-reserved slice, which would push a true 4 GB unit
    # under the threshold). Fall back to ComputerSystem if the modules can't be read.
    $ramBytes = ( @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue) |
                  Measure-Object -Property Capacity -Sum ).Sum
    if (-not $ramBytes -and $cs) { $ramBytes = $cs.TotalPhysicalMemory }
    $ramGB = [math]::Round(($ramBytes / 1GB), 0)

    $model = if ($cs) { "$($cs.Manufacturer) $($cs.Model)".Trim() } else { "unknown" }

    # System drive free space + media type.
    $sysDrive = ($env:SystemDrive).TrimEnd(':')
    $logical  = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue
    $freeGB   = if ($logical) { [math]::Round(($logical.FreeSpace / 1GB), 1) } else { 0 }
    $totalGB  = if ($logical) { [math]::Round(($logical.Size / 1GB), 0) } else { 0 }

    $isHdd = $false
    try {
        $phys = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq 0 } | Select-Object -First 1
        if ($phys -and $phys.MediaType -eq 'HDD') { $isHdd = $true }
    } catch {}

    # --- Report the facts ---
    Write-Log "Model:   $model"
    if ($cpu) { Write-Log "CPU:     $($cpu.Name.Trim()) ($($cpu.NumberOfCores) cores)" }
    Write-Log "RAM:     $ramGB GB installed"
    Write-Log "Disk:    $sysDrive drive, $freeGB GB free of $totalGB GB$(if ($isHdd) { ' (spinning HDD)' })"
    if ($os) { Write-Log "Windows: $($os.Caption) build $($os.BuildNumber)" }
    Write-Log ""

    # --- Verdict ---
    # Never condemn a unit we simply couldn't read. If RAM came back as zero the
    # probe failed, not the hardware - warn and let the tech check manually rather
    # than telling them to replace a machine that might be fine.
    if ($ramGB -le 0) {
        Write-Log "Could not read this device's memory. Check the spec manually (Settings > System > About) before deciding." "WARN"
        Write-Log "As a rule: under 4 GB RAM is unsuitable; 4-7 GB is usable but wipe/reimage first if sluggish; 8 GB+ is fine." "WARN"
        return
    }

    $verdict = Get-HardwareVerdict -RamGB $ramGB -FreeDiskGB $freeGB -Model $model -IsRotationalDisk $isHdd

    $level = switch ($verdict.Level) { 'OK' { 'OK' } 'WARN' { 'WARN' } default { 'ERROR' } }
    Write-Log "VERDICT: $($verdict.Summary)" $level
    foreach ($line in $verdict.Advice) { Write-Log "  - $line" $level }

    if ($verdict.Level -eq 'FAIL') {
        Write-Log ""
        Write-Log "Recommended: do not migrate this unit. Replace it, or confirm with the venue before proceeding." "ERROR"
    } elseif ($verdict.Level -eq 'WARN') {
        Write-Log ""
        Write-Log "You can proceed, but read the advice above first - a wipe/reimage before migrating may save a return visit." "WARN"
    } else {
        Write-Log ""
        Write-Log "Good to go. Continue with the migration." "OK"
    }
}
