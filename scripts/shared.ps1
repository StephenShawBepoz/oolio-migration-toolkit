# shared.ps1 - helper functions dot-sourced by every module script

# Read a value from the Bepoz registry key (HKCU:\Software\Backoffice)
function Get-BepozRegValue {
    param([string]$valueName)
    try {
        return (Get-ItemProperty -Path "HKCU:\Software\Backoffice" -Name $valueName -ErrorAction Stop).$valueName
    } catch {
        return $null
    }
}

# Write a timestamped log line. Picked up by the SSE stream.
function Write-Log {
    param([string]$message, [string]$level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Output "[$ts][$level] $message"
}

# Write a section header.
function Write-Section {
    param([string]$title)
    Write-Output ""
    Write-Output "--- $title ---"
}

# Emit a structured progress event. The server filters these out of the session
# log; the UI parses them to drive a progress bar above the output panel. Sent
# at most once per second so the log file stays clean and the bar stays smooth.
function Write-ProgressEvent {
    param(
        [string]$Label,
        [int64]$Current = 0,
        [int64]$Total   = 0,
        [int]$ElapsedSeconds = 0,
        [bool]$Done = $false
    )
    $payload = @{
        label   = $Label
        current = $Current
        total   = $Total
        elapsed = $ElapsedSeconds
        done    = $Done
    } | ConvertTo-Json -Compress
    Write-Output "__PROGRESS__: $payload"
}

# Find installed programs by registry scan. Returns objects with DisplayName,
# DisplayVersion, UninstallString, QuietUninstallString, Publisher, and the
# source registry path. Avoids Win32_Product (which triggers an MSI
# reconfigure on every installed package). The match is a -like wildcard so
# callers can pass "*Bepoz*", "TeamViewer", etc.
function Get-InstalledProgram {
    param([Parameter(Mandatory)] [string]$NameLike)
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $results = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName -and ($p.DisplayName -like $NameLike)) {
                $results += [pscustomobject]@{
                    DisplayName          = $p.DisplayName
                    DisplayVersion       = $p.DisplayVersion
                    Publisher            = $p.Publisher
                    UninstallString      = $p.UninstallString
                    QuietUninstallString = $p.QuietUninstallString
                    RegistryPath         = $_.PSPath
                }
            }
        }
    }
    return $results
}

# Write a registry value into every local user's HKCU hive plus the .DEFAULT
# template (so new profiles inherit it too). Use for POS-hardening tweaks that
# need to apply to the autologon POS user even when the toolkit ran under a
# different admin account. Loaded hives are always unloaded (even on failure)
# so the registry stays clean.
function Set-RegistryForAllUsers {
    param(
        [Parameter(Mandatory)] [string]$SubKey,    # e.g. "SOFTWARE\Microsoft\TabletTip\1.7"
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Value,
        [ValidateSet('DWord','String','ExpandString','MultiString','Binary','QWord')]
        [string]$Type = 'DWord'
    )

    # New-profile coverage: HKU\.DEFAULT is the SYSTEM logon profile, and the
    # actual template new users inherit from is C:\Users\Default\NTUSER.DAT -
    # load that like any other offline profile hive. (The previous target here
    # was HKLM\.DEFAULT, which does not exist: writes landed in a junk
    # HKLM\.DEFAULT key tree while logging OK, and new profiles got nothing.)
    $targets = @()
    $defaultTemplate = Join-Path $env:SystemDrive "Users\Default\NTUSER.DAT"
    if (Test-Path $defaultTemplate) {
        $targets += @{ Hive = "HKU\Oolio_DefaultTemplate"; LoadPath = $defaultTemplate; Label = "Default user template" }
    }

    # Loaded hives appear under HKEY_USERS\<SID>. Walk every profile in
    # ProfileList, skipping system accounts and already-loaded ones.
    $profileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    $loadedSids = @{}
    Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | ForEach-Object {
        $loadedSids[$_.PSChildName] = $true
    }

    Get-ChildItem $profileListKey -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        if ($sid -like "S-1-5-18*" -or $sid -like "S-1-5-19*" -or $sid -like "S-1-5-20*") { return }
        if ($sid.EndsWith("_Classes")) { return }
        $profilePath = (Get-ItemProperty -Path $_.PSPath -Name "ProfileImagePath" -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profilePath) { return }
        if ($loadedSids.ContainsKey($sid)) {
            $targets += @{ Hive = "HKU\$sid"; LoadPath = $null; Label = "$sid (loaded)" }
        } else {
            $ntuser = Join-Path $profilePath "NTUSER.DAT"
            if (Test-Path $ntuser) {
                $targets += @{ Hive = "HKU\Oolio_$sid"; LoadPath = $ntuser; Label = "$sid (loading from $ntuser)" }
            }
        }
    }

    foreach ($t in $targets) {
        $loaded = $false
        try {
            if ($t.LoadPath) {
                $hiveName = $t.Hive.Replace("HKU\", "")
                $null = reg.exe load $t.Hive "`"$($t.LoadPath)`"" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "  Skip $($t.Label) - reg load failed (file in use?)" "WARN"
                    continue
                }
                $loaded = $true
            }
            $regPath = $t.Hive.Replace("HKU\", "Registry::HKEY_USERS\").Replace("HKLM\", "Registry::HKEY_LOCAL_MACHINE\") + "\$SubKey"
            if (-not (Test-Path $regPath)) {
                New-Item -Path $regPath -Force | Out-Null
            }
            New-ItemProperty -Path $regPath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
            Write-Log "  $($t.Label) :: $SubKey\$Name = $Value" "OK"
        } catch {
            Write-Log "  $($t.Label) :: failed - $($_.Exception.Message)" "WARN"
        } finally {
            if ($loaded) {
                # The registry provider (or AV / indexers) can hold a transient
                # handle into the hive; a single blind unload can fail silently
                # and leave NTUSER.DAT locked so the user cannot sign in. Retry
                # with GC pressure between attempts and report a failure loudly.
                $unloaded = $false
                for ($attempt = 1; $attempt -le 4 -and -not $unloaded; $attempt++) {
                    [gc]::Collect()
                    [gc]::WaitForPendingFinalizers()
                    Start-Sleep -Milliseconds (200 * $attempt)
                    $null = reg.exe unload $t.Hive 2>&1
                    if ($LASTEXITCODE -eq 0) { $unloaded = $true }
                }
                if (-not $unloaded) {
                    Write-Log "  $($t.Label) :: hive $($t.Hive) could NOT be unloaded after 4 attempts - $($t.LoadPath) stays locked until reboot. The user may be unable to sign in until then." "ERROR"
                }
            }
        }
    }
}

# Retry wrapper around Invoke-DownloadWithHeartbeat. Three attempts with
# exponential backoff (2s, 4s, 8s). Logs each retry so techs see what's
# happening. Returns the boolean result of the final attempt.
function Invoke-DownloadWithRetry {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$ProgressLabel = "Downloading",
        [int]$MaxAttempts = 3
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            $backoff = [int][math]::Pow(2, $attempt - 1)
            Write-Log "Retry $($attempt-1) failed. Waiting ${backoff}s before next attempt..." "WARN"
            Start-Sleep -Seconds $backoff
        }
        $ok = Invoke-DownloadWithHeartbeat -Url $Url -OutFile $OutFile -ProgressLabel "$ProgressLabel (attempt $attempt/$MaxAttempts)"
        if ($ok) { return $true }
    }
    Write-Log "All $MaxAttempts download attempts failed." "ERROR"
    return $false
}

# Download a file with a heartbeat. Pre-flights a HEAD request to learn the
# total size for a determinate progress bar; falls back to indeterminate if
# Content-Length is unavailable. Emits two cadences:
#   - Write-Log every $LogIntervalSeconds (default 5s) - persisted to session log
#   - Write-ProgressEvent every $ProgressIntervalSeconds (default 1s) - UI bar
# Returns $true on success, $false on failure (caller already sees [ERROR]).
function Invoke-DownloadWithHeartbeat {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$ProgressLabel        = "Downloading",
        [int]$LogIntervalSeconds      = 5,
        [int]$ProgressIntervalSeconds = 1
    )

    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

    # HEAD pre-flight for total size. Best-effort - some CDNs strip Content-Length
    # on HEAD, in which case we just show an indeterminate bar.
    $totalBytes = 0
    try {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop -TimeoutSec 10
        if ($resp.Headers['Content-Length']) {
            $totalBytes = [int64]$resp.Headers['Content-Length']
            Write-Log ("Expected size: {0:N1} MB" -f ($totalBytes / 1MB))
        }
    } catch {
        # HEAD failed - proceed with indeterminate progress
    }

    Write-ProgressEvent -Label $ProgressLabel -Current 0 -Total $totalBytes -ElapsedSeconds 0

    $job = Start-Job -ScriptBlock {
        param($u, $o)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -ErrorAction Stop
    } -ArgumentList $Url, $OutFile

    $start    = Get-Date
    $lastLog  = $start
    $lastProg = $start
    while ($job.State -eq 'Running') {
        Start-Sleep -Milliseconds 250
        $now = Get-Date
        $elapsed = [int]($now - $start).TotalSeconds

        $sizeBytes = 0
        if (Test-Path $OutFile) {
            try { $sizeBytes = (Get-Item $OutFile).Length } catch {}
        }

        if (($now - $lastProg).TotalSeconds -ge $ProgressIntervalSeconds) {
            Write-ProgressEvent -Label $ProgressLabel -Current $sizeBytes -Total $totalBytes -ElapsedSeconds $elapsed
            $lastProg = $now
        }

        if (($now - $lastLog).TotalSeconds -ge $LogIntervalSeconds) {
            $sizeMB = [math]::Round($sizeBytes / 1MB, 1)
            if ($totalBytes -gt 0) {
                $totalMB = [math]::Round($totalBytes / 1MB, 1)
                $pct = [int](($sizeBytes / [double]$totalBytes) * 100)
                Write-Log "still downloading... $sizeMB / $totalMB MB ($pct%) after ${elapsed}s"
            } else {
                Write-Log "still downloading... $sizeMB MB after ${elapsed}s"
            }
            $lastLog = $now
        }
    }

    try { Receive-Job $job -ErrorAction Stop | Out-Null } catch {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
        Write-ProgressEvent -Label $ProgressLabel -Current 0 -Total 0 -ElapsedSeconds 0 -Done $true
        Write-Log "Download failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
        Write-ProgressEvent -Label $ProgressLabel -Current 0 -Total 0 -ElapsedSeconds 0 -Done $true
        Write-Log "Download finished but the file is missing or empty." "ERROR"
        return $false
    }

    $finalBytes = (Get-Item $OutFile).Length
    $finalSize  = [math]::Round($finalBytes / 1MB, 1)
    $totalDl    = [int]((Get-Date) - $start).TotalSeconds
    Write-ProgressEvent -Label $ProgressLabel -Current $finalBytes -Total $finalBytes -ElapsedSeconds $totalDl -Done $true
    Write-Log "Downloaded: $finalSize MB to $OutFile in ${totalDl}s" "OK"
    return $true
}

# Verify that a downloaded file has a valid Authenticode signature, optionally
# matching a wildcard pattern on the signer's subject (e.g. "*Google LLC*").
# Returns $true if the signature is Valid (and matches the pattern when given),
# $false otherwise. Logs the outcome via Write-Log.
function Test-InstallerSignature {
    param(
        [string]$Path,
        [string]$ExpectedSubjectLike
    )

    if (-not (Test-Path $Path)) {
        Write-Log "Cannot verify signature: file not found at $Path" "ERROR"
        return $false
    }

    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    } catch {
        Write-Log "Failed to read Authenticode signature: $($_.Exception.Message)" "ERROR"
        return $false
    }

    if ($sig.Status -ne 'Valid') {
        Write-Log "Authenticode signature status is '$($sig.Status)' (expected Valid)." "ERROR"
        if ($sig.StatusMessage) { Write-Log "Detail: $($sig.StatusMessage)" "ERROR" }
        return $false
    }

    $subject = ""
    if ($sig.SignerCertificate) { $subject = $sig.SignerCertificate.Subject }
    Write-Log "Signature: Valid - signed by $subject" "OK"

    if ($ExpectedSubjectLike -and ($subject -notlike $ExpectedSubjectLike)) {
        Write-Log "Signer subject does not match expected pattern '$ExpectedSubjectLike'. Refusing to run installer." "ERROR"
        return $false
    }

    return $true
}

# Wait for a process started with -PassThru. Emits an indeterminate progress
# event every $ProgressIntervalSeconds (default 1s) for the UI bar, plus a
# textual heartbeat every $LogIntervalSeconds (default 5s) for the session log.
# msiexec /qn does not expose progress so the bar is animated stripes only.
function Wait-ProcessWithHeartbeat {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Label                = "process",
        [int]$LogIntervalSeconds      = 5,
        [int]$ProgressIntervalSeconds = 1
    )

    Write-ProgressEvent -Label $Label -Current 0 -Total 0 -ElapsedSeconds 0

    $start    = Get-Date
    $lastLog  = $start
    $lastProg = $start
    while (-not $Process.HasExited) {
        Start-Sleep -Milliseconds 250
        $now = Get-Date
        $elapsed = [int]($now - $start).TotalSeconds

        if (($now - $lastProg).TotalSeconds -ge $ProgressIntervalSeconds) {
            Write-ProgressEvent -Label $Label -Current 0 -Total 0 -ElapsedSeconds $elapsed
            $lastProg = $now
        }

        if (($now - $lastLog).TotalSeconds -ge $LogIntervalSeconds) {
            $stamp = "{0}:{1:00}" -f [int]($elapsed / 60), ($elapsed % 60)
            Write-Log "$Label still running, elapsed $stamp"
            $lastLog = $now
        }
    }

    $totalElapsed = [int]((Get-Date) - $start).TotalSeconds
    Write-ProgressEvent -Label $Label -Current 0 -Total 0 -ElapsedSeconds $totalElapsed -Done $true
}
