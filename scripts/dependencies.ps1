# dependencies.ps1 - Module 3: Oolio Dependencies step functions

function Invoke-DepsInstallTeamViewer {
    Write-Section "Installing TeamViewer (full version)"

    $tvPaths = @(
        "C:\Program Files\TeamViewer\TeamViewer.exe",
        "C:\Program Files (x86)\TeamViewer\TeamViewer.exe"
    )
    foreach ($p in $tvPaths) {
        if (Test-Path $p) {
            $ver = (Get-Item $p).VersionInfo.FileVersion
            Write-Log "TeamViewer already installed at: $p" "OK"
            Write-Log "Version: $ver"
            return
        }
    }

    Write-Log "TeamViewer not found. Downloading installer..." "WARN"

    $url       = "https://download.teamviewer.com/download/TeamViewer_Setup_x64.exe"
    $installer = Join-Path $env:TEMP "TeamViewer_Setup_x64.exe"

    Write-Log "Source: $url"
    if (-not (Invoke-DownloadWithRetry -Url $url -OutFile $installer -ProgressLabel "Downloading TeamViewer")) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    if (-not (Test-InstallerSignature -Path $installer -ExpectedSubjectLike "*TeamViewer*")) {
        Write-Log "Refusing to run unverified installer. The downloaded EXE may be corrupt or tampered with." "ERROR"
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log "Installing silently (/S)..."
    $proc = Start-Process -FilePath $installer -ArgumentList "/S" -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing TeamViewer"
    $proc.WaitForExit()
    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch {}
    Write-Log "Installer exit code: $(if ($null -eq $exitCode) { '(null - process handle lost)' } else { $exitCode })"

    # The /S installer hands off to a background service installer and exits before
    # TeamViewer.exe is fully written to Program Files, so a single check straight
    # after exit reports a false failure. Poll instead.
    Write-Log "Waiting for TeamViewer to appear on disk..."
    $pollDeadline = (Get-Date).AddMinutes(3)
    $start   = Get-Date
    $lastLog = $start
    $found   = $false
    $foundPath = $null
    while ((Get-Date) -lt $pollDeadline -and -not $found) {
        foreach ($p in $tvPaths) {
            if (Test-Path $p) { $found = $true; $foundPath = $p; break }
        }
        if (-not $found) {
            $now = Get-Date
            if (($now - $lastLog).TotalSeconds -ge 10) {
                Write-Log "Still waiting for TeamViewer.exe... ($([int]($now - $start).TotalSeconds)s)"
                $lastLog = $now
            }
            Start-Sleep -Seconds 2
        }
    }

    if ($found) {
        $ver = (Get-Item $foundPath).VersionInfo.FileVersion
        Write-Log "TeamViewer installed and verified: $foundPath version $ver" "OK"
        if ($null -ne $exitCode -and $exitCode -ne 0) {
            Write-Log "Note: installer exit code was $exitCode (non-standard but TeamViewer is present)." "WARN"
        }
    } else {
        Write-Log "TeamViewer.exe was not found on disk after 3 minutes (exit code $exitCode)." "ERROR"
        Write-Log "Check Programs and Features, or install manually. Antivirus can also block the silent install." "WARN"
    }

    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}

function Invoke-DepsCheckWebView2 {
    Write-Section "Checking Edge WebView2"

    $regPath   = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    $installed = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue

    if ($installed) {
        Write-Log "Edge WebView2 is installed." "OK"
        Write-Log "Version: $($installed.pv)"
        return
    }

    Write-Log "Edge WebView2 not found. Downloading Evergreen Bootstrapper..." "WARN"

    $url       = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
    $installer = Join-Path $env:TEMP "MicrosoftEdgeWebview2Setup.exe"

    Write-Log "Source: $url"
    if (-not (Invoke-DownloadWithRetry -Url $url -OutFile $installer -ProgressLabel "Downloading Edge WebView2")) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    if (-not (Test-InstallerSignature -Path $installer -ExpectedSubjectLike "*Microsoft Corporation*")) {
        Write-Log "Refusing to run unverified installer. The downloaded EXE may be corrupt or tampered with." "ERROR"
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log "Installing silently (/silent /install)..."
    $proc = Start-Process -FilePath $installer -ArgumentList @("/silent", "/install") -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing WebView2"

    if ($proc.ExitCode -eq 0) {
        $installed = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($installed) {
            Write-Log "Edge WebView2 installed successfully." "OK"
            Write-Log "Version: $($installed.pv)"
        } else {
            Write-Log "Installer reported success but the EdgeUpdate Clients registry key is still missing." "WARN"
            Write-Log "WebView2 may need a reboot to register, or the bootstrapper failed silently. Check Programs and Features." "WARN"
        }
    } else {
        Write-Log "WebView2 installer exited with code $($proc.ExitCode)." "ERROR"
    }

    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}


function Invoke-DepsCheckEpsonNetConfig {
    Write-Section "Checking EpsonNet Config"

    $knownPaths = @(
        "C:\Program Files (x86)\EpsonNet\EpsonNet Config V4\ENConfig.exe",
        "C:\Program Files\EpsonNet\EpsonNet Config V4\ENConfig.exe",
        "C:\Program Files (x86)\EPSON\EpsonNetConfig\ENConfig.exe",
        "C:\Program Files\EPSON\EpsonNetConfig\ENConfig.exe"
    )
    foreach ($p in $knownPaths) {
        if (Test-Path $p) {
            Write-Log "EpsonNet Config found at: $p" "OK"
            Write-Log "Version: $((Get-Item $p).VersionInfo.FileVersion)"
            return
        }
    }

    $regInstalled = @(
        Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'EpsonNet Config' }
        Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'EpsonNet Config' }
    )
    if ($regInstalled.Count -gt 0) {
        Write-Log "EpsonNet Config is installed: $($regInstalled[0].DisplayName) $($regInstalled[0].DisplayVersion)" "OK"
        return
    }

    Write-Log "EpsonNet Config not found. Downloading installer..." "WARN"

    $url       = "https://ftp.epson.com/drivers/ENCU_4.9.11.exe"
    $installer = Join-Path $env:TEMP "ENCU_4.9.11.exe"

    Write-Log "Source: $url"
    if (-not (Invoke-DownloadWithHeartbeat -Url $url -OutFile $installer -ProgressLabel "Downloading EpsonNet Config")) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    if (-not (Test-InstallerSignature -Path $installer -ExpectedSubjectLike "*EPSON*")) {
        Write-Log "Refusing to run unverified installer. The downloaded EXE may be corrupt or tampered with." "ERROR"
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        return
    }

    # The EpsonNet Config installer is a WinZip SFX wrapper around an InstallShield
    # wizard. Neither layer honours /S or /SILENT, and InstallShield ignores
    # synthetic BM_CLICK window messages - automating the clicks was tried and does
    # not work. Launch it, print instructions, and poll for the binary instead.
    Write-Log ""
    Write-Log "===================================================================" "WARN"
    Write-Log "MANUAL ACTION REQUIRED - click through the EpsonNet Config wizard:" "WARN"
    Write-Log "  1. Epson Installer dialog       -> click OK" "WARN"
    Write-Log "  2. WinZip Self-Extractor        -> click Setup" "WARN"
    Write-Log "  3. Select Setup Language        -> click Next" "WARN"
    Write-Log "  4. Welcome screen               -> click Next" "WARN"
    Write-Log "  5. License Agreement            -> select 'I accept', click Next" "WARN"
    Write-Log "  6. Choose Destination Location  -> click Next" "WARN"
    Write-Log "  7. Ready to Install             -> click Install" "WARN"
    Write-Log "  8. Setup Complete               -> click Finish" "WARN"
    Write-Log "===================================================================" "WARN"
    Write-Log ""
    Write-Log "Launching installer - the toolkit will detect completion automatically." "OK"

    Start-Process -FilePath $installer

    $pollDeadline = (Get-Date).AddMinutes(10)
    $start   = Get-Date
    $lastLog = $start
    $found   = $false
    while ((Get-Date) -lt $pollDeadline -and -not $found) {
        foreach ($p in $knownPaths) {
            if (Test-Path $p) {
                Write-Log "EpsonNet Config installed and verified: $p version $((Get-Item $p).VersionInfo.FileVersion)" "OK"
                $found = $true
                break
            }
        }
        if ($found) { break }

        $regCheck = @(
            Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'EpsonNet Config' }
        )
        if ($regCheck.Count -gt 0) {
            Write-Log "EpsonNet Config installed (registry): $($regCheck[0].DisplayName) $($regCheck[0].DisplayVersion)" "OK"
            $found = $true
            break
        }

        $now = Get-Date
        if (($now - $lastLog).TotalSeconds -ge 15) {
            Write-Log "Still waiting for EpsonNet Config install to complete... ($([int]($now - $start).TotalSeconds)s)"
            $lastLog = $now
        }
        Start-Sleep -Seconds 2
    }

    if (-not $found) {
        Write-Log "Timed out after 10 minutes. EpsonNet Config was not detected." "ERROR"
        Write-Log "If you did not complete the wizard, re-run this step. If you did complete it but the toolkit didn't detect it, check Program Files manually." "WARN"
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        return
    }

    # Remove desktop shortcuts left by the Epson installer.
    foreach ($dir in @("C:\Users\Public\Desktop", "$env:USERPROFILE\Desktop")) {
        Get-ChildItem -Path $dir -Filter "*EpsonNet*" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "Removed desktop shortcut: $($_.Name)" "OK"
        }
    }

    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}
