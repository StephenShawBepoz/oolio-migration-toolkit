# dependencies.ps1 - Module 3: Oolio Dependencies step functions

function Invoke-DepsCheckChrome {
    Write-Section "Checking Google Chrome"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "This step requires administrator privileges. Please restart the toolkit as Administrator (right-click Launch.ps1 -> Run as administrator)." "ERROR"
        return
    }

    $chromePath    = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    $chromePathx86 = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"

    if (Test-Path $chromePath) {
        $ver = (Get-Item $chromePath).VersionInfo.FileVersion
        Write-Log "Chrome found at: $chromePath" "OK"
        Write-Log "Version: $ver"
        return
    }
    if (Test-Path $chromePathx86) {
        $ver = (Get-Item $chromePathx86).VersionInfo.FileVersion
        Write-Log "Chrome found at: $chromePathx86" "OK"
        Write-Log "Version: $ver"
        return
    }

    Write-Log "Chrome not found. Downloading enterprise installer..." "WARN"

    $msiUrl  = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
    $msiPath = Join-Path $env:TEMP "googlechromestandaloneenterprise64.msi"
    $logPath = Join-Path $env:TEMP "chrome-install.log"

    Write-Log "Source: $msiUrl"
    if (-not (Invoke-DownloadWithHeartbeat -Url $msiUrl -OutFile $msiPath -ProgressLabel "Downloading Google Chrome")) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    if (-not (Test-InstallerSignature -Path $msiPath -ExpectedSubjectLike "*Google LLC*")) {
        Write-Log "Refusing to run unverified installer. The downloaded MSI may be corrupt or tampered with." "ERROR"
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log "Installing silently (msiexec /i /qn /norestart)..."
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "`"$msiPath`"", "/qn", "/norestart", "/l*v", "`"$logPath`"") -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing Chrome (msiexec)"
    $proc.WaitForExit()
    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch {}
    Write-Log "msiexec exit code: $(if ($null -eq $exitCode) { '(null - process handle lost)' } else { $exitCode })"

    # The Chrome enterprise MSI extracts a mini_installer.exe and launches it, then
    # reports success. mini_installer.exe continues running in the background and
    # writes chrome.exe to Program Files after the MSI process exits. Poll for up
    # to 3 minutes rather than using a fixed sleep.
    Write-Log "Waiting for Chrome to appear on disk (mini_installer may still be running)..."
    $pollDeadline = (Get-Date).AddMinutes(3)
    $start        = Get-Date
    $lastLog      = $start
    $chromeFound  = $false
    while ((Get-Date) -lt $pollDeadline -and -not $chromeFound) {
        $chromeFound = (Test-Path $chromePath) -or (Test-Path $chromePathx86)
        if (-not $chromeFound) {
            $now = Get-Date
            if (($now - $lastLog).TotalSeconds -ge 10) {
                $elapsed = [int]($now - $start).TotalSeconds
                Write-Log "Still waiting for chrome.exe... (${elapsed}s)"
                $lastLog = $now
            }
            Start-Sleep -Seconds 2
        }
    }

    # msiexec success codes: 0 = success, 3010 = success (restart required),
    # 1641 = success (restart initiated), 1638 = newer version already present.
    $msiSuccessCodes = @(0, 3010, 1641, 1638)

    if ($chromeFound) {
        $verPath = if (Test-Path $chromePath) { $chromePath } else { $chromePathx86 }
        $ver = (Get-Item $verPath).VersionInfo.FileVersion
        Write-Log "Chrome installed and verified: $verPath version $ver" "OK"
        if ($exitCode -notin $msiSuccessCodes) {
            Write-Log "Note: msiexec exit code was $exitCode (non-standard but Chrome is present)." "WARN"
        }
    } else {
        Write-Log "Chrome was not found on disk after 3 minutes." "ERROR"
        Write-Log "Common msiexec codes: 1618 = another installer running; 1619 = MSI could not be opened; 1603 = fatal error." "WARN"
        if (Test-Path $logPath) {
            Write-Log "--- MSI install log (last 30 lines) ---" "WARN"
            $tail = Get-Content $logPath -Tail 30 -ErrorAction SilentlyContinue
            foreach ($line in $tail) {
                # Only flag lines with genuine failure indicators, not lines that
                # merely contain the word 'error' in a success message.
                if ($line -match 'return value 3|Installation failed|Error 1[0-9]{3}' ) {
                    Write-Log $line "ERROR"
                } elseif ($line.Trim().Length -gt 0) {
                    Write-Log $line
                }
            }
            Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
}

function Invoke-DepsInstallTeamViewer {
    Write-Section "Installing TeamViewer (full version)"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "This step requires administrator privileges. Please restart the toolkit as Administrator (right-click Launch.ps1 -> Run as administrator)." "ERROR"
        return
    }

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
    if (-not (Invoke-DownloadWithHeartbeat -Url $url -OutFile $installer -ProgressLabel "Downloading TeamViewer")) {
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

    # Give the TeamViewer background service installer a moment to finish writing
    # files after the outer process exits.
    Start-Sleep -Seconds 5

    $tvFound = $false
    foreach ($p in $tvPaths) {
        if (Test-Path $p) {
            $ver = (Get-Item $p).VersionInfo.FileVersion
            Write-Log "TeamViewer installed and verified: $p version $ver" "OK"
            $tvFound = $true
            break
        }
    }

    if (-not $tvFound) {
        if ($proc.ExitCode -eq 0) {
            Write-Log "Installer exited cleanly but TeamViewer.exe was not found. It may still be installing - check Program Files in a moment." "WARN"
        } else {
            Write-Log "TeamViewer installer exited with code $($proc.ExitCode) and TeamViewer.exe was not found on disk." "ERROR"
        }
    } elseif ($proc.ExitCode -ne 0) {
        Write-Log "Note: installer exit code was $($proc.ExitCode) (non-standard but TeamViewer is present)." "WARN"
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
            $ver = (Get-Item $p).VersionInfo.FileVersion
            Write-Log "EpsonNet Config found at: $p" "OK"
            Write-Log "Version: $ver"
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
    # wizard. /SILENT is not honoured by either layer, and InstallShield wizards
    # routinely ignore synthetic BM_CLICK window messages — so we don't try to
    # automate the clicks. Instead: launch the installer, print clear instructions,
    # and poll for the binary to appear on disk.
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

    # Poll for the installed binary at the known paths. Up to 10 minutes -
    # plenty of time for a technician to click through the wizard.
    $pollDeadline = (Get-Date).AddMinutes(10)
    $start = Get-Date
    $lastLog = $start
    $found = $false
    while ((Get-Date) -lt $pollDeadline -and -not $found) {
        foreach ($p in $knownPaths) {
            if (Test-Path $p) {
                $ver = (Get-Item $p).VersionInfo.FileVersion
                Write-Log "EpsonNet Config installed and verified: $p version $ver" "OK"
                $found = $true
                break
            }
        }
        if (-not $found) {
            # Also poll the uninstall registry as a fallback in case the install
            # path differs from any of the known ones.
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
                $elapsed = [int]($now - $start).TotalSeconds
                Write-Log "Still waiting for EpsonNet Config install to complete... (${elapsed}s)"
                $lastLog = $now
            }
            Start-Sleep -Seconds 2
        }
    }

    if (-not $found) {
        Write-Log "Timed out after 10 minutes. EpsonNet Config was not detected." "ERROR"
        Write-Log "If you did not complete the wizard, re-run this step. If you did complete it but the toolkit didn't detect it, check Program Files manually." "WARN"
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        return
    }

    # Remove desktop shortcuts left by the Epson installer.
    $desktopPaths = @(
        "C:\Users\Public\Desktop",
        "$env:USERPROFILE\Desktop"
    )
    foreach ($dir in $desktopPaths) {
        Get-ChildItem -Path $dir -Filter "*EpsonNet*" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "Removed desktop shortcut: $($_.Name)" "OK"
        }
    }

    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}

function Invoke-DepsCheckWebView2 {
    Write-Section "Checking Edge WebView2"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "This step requires administrator privileges. Please restart the toolkit as Administrator (right-click Launch.ps1 -> Run as administrator)." "ERROR"
        return
    }

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
    if (-not (Invoke-DownloadWithHeartbeat -Url $url -OutFile $installer -ProgressLabel "Downloading Edge WebView2")) {
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

