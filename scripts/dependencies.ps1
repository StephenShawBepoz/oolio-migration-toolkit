# dependencies.ps1 - Module 3: Oolio Dependencies step functions

function Invoke-DepsCheckChrome {
    Write-Section "Checking Google Chrome"

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
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "`"$msiPath`"", "/qn", "/norestart") -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing Chrome (msiexec)"

    if ($proc.ExitCode -eq 0) {
        Write-Log "Chrome installed successfully." "OK"
        if (Test-Path $chromePath) {
            $ver = (Get-Item $chromePath).VersionInfo.FileVersion
            Write-Log "Verified: $chromePath version $ver" "OK"
        } elseif (Test-Path $chromePathx86) {
            $ver = (Get-Item $chromePathx86).VersionInfo.FileVersion
            Write-Log "Verified: $chromePathx86 version $ver" "OK"
        }
    } else {
        Write-Log "msiexec exited with code $($proc.ExitCode)." "ERROR"
    }

    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
}

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

    if ($proc.ExitCode -eq 0) {
        Write-Log "TeamViewer installer exited cleanly." "OK"
        $found = $false
        foreach ($p in $tvPaths) {
            if (Test-Path $p) {
                $ver = (Get-Item $p).VersionInfo.FileVersion
                Write-Log "Verified: $p version $ver" "OK"
                $found = $true
                break
            }
        }
        if (-not $found) {
            Write-Log "Installer reported success but TeamViewer.exe was not found. Check Program Files manually." "WARN"
        }
    } else {
        Write-Log "TeamViewer installer exited with code $($proc.ExitCode)." "ERROR"
    }

    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}

function Invoke-DepsCheckEpsonNetConfig {
    Write-Section "Checking EpsonNet Config"

    $knownPaths = @(
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

    Write-Log "Installing silently (/SILENT)..."
    $proc = Start-Process -FilePath $installer -ArgumentList "/SILENT" -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing EpsonNet Config"

    if ($proc.ExitCode -eq 0) {
        Write-Log "EpsonNet Config installer exited cleanly." "OK"
        $found = $false
        foreach ($p in $knownPaths) {
            if (Test-Path $p) {
                $ver = (Get-Item $p).VersionInfo.FileVersion
                Write-Log "Verified: $p version $ver" "OK"
                $found = $true
                break
            }
        }
        if (-not $found) {
            $check = @(
                Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -match 'EpsonNet Config' }
            )
            if ($check.Count -gt 0) {
                Write-Log "Verified via registry: $($check[0].DisplayName) $($check[0].DisplayVersion)" "OK"
                $found = $true
            }
        }
        if (-not $found) {
            Write-Log "Installer reported success but EpsonNet Config was not found at known paths. Check Program Files manually." "WARN"
        }
    } else {
        Write-Log "EpsonNet Config installer exited with code $($proc.ExitCode)." "ERROR"
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

