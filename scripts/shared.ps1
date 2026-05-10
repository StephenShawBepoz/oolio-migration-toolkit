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

# Download a file with a heartbeat that emits the on-disk size every few seconds.
# Returns $true on success, $false on failure (caller already sees an [ERROR] line).
function Invoke-DownloadWithHeartbeat {
    param(
        [string]$Url,
        [string]$OutFile,
        [int]$IntervalSeconds = 3
    )

    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

    $job = Start-Job -ScriptBlock {
        param($u, $o)
        # Tls13 may not be defined on older .NET; fall back to Tls12-only if so.
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -ErrorAction Stop
    } -ArgumentList $Url, $OutFile

    $start    = Get-Date
    $lastBeat = $start
    while ($job.State -eq 'Running') {
        Start-Sleep -Milliseconds 500
        $now = Get-Date
        if (($now - $lastBeat).TotalSeconds -ge $IntervalSeconds) {
            $elapsed = [int]($now - $start).TotalSeconds
            $sizeMB  = 0
            if (Test-Path $OutFile) {
                $sizeMB = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
            }
            Write-Log "still downloading... $sizeMB MB after ${elapsed}s"
            $lastBeat = $now
        }
    }

    try { Receive-Job $job -ErrorAction Stop | Out-Null } catch {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
        Write-Log "Download failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
        Write-Log "Download finished but the file is missing or empty." "ERROR"
        return $false
    }

    $finalSize = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
    $totalDl   = [int]((Get-Date) - $start).TotalSeconds
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

# Wait for a process started with -PassThru, emitting a heartbeat every N seconds.
function Wait-ProcessWithHeartbeat {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Label = "process",
        [int]$IntervalSeconds = 5
    )

    $start    = Get-Date
    $lastBeat = $start
    while (-not $Process.HasExited) {
        Start-Sleep -Milliseconds 500
        $now = Get-Date
        if (($now - $lastBeat).TotalSeconds -ge $IntervalSeconds) {
            $e = $now - $start
            $stamp = "{0}:{1:00}" -f [int]$e.TotalMinutes, ([int]$e.TotalSeconds % 60)
            Write-Log "$Label still running, elapsed $stamp"
            $lastBeat = $now
        }
    }
}
