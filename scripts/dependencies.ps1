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
    if (-not (Invoke-DownloadWithHeartbeat -Url $msiUrl -OutFile $msiPath)) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    Write-Log "Installing silently (msiexec /i /qn /norestart)..."
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "`"$msiPath`"", "/qn", "/norestart") -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "msiexec"

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
    if (-not (Invoke-DownloadWithHeartbeat -Url $url -OutFile $installer)) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    Write-Log "Installing silently (/S)..."
    $proc = Start-Process -FilePath $installer -ArgumentList "/S" -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "TeamViewer installer"

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

function Invoke-DepsCheckWebView2 {
    Write-Section "Checking Edge WebView2"

    $regPath = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    $installed = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue

    if ($installed) {
        Write-Log "Edge WebView2 is installed." "OK"
        Write-Log "Version: $($installed.pv)"
    } else {
        Write-Log "Edge WebView2 not found." "WARN"
        Write-Log "Required for Windows native Oolio POS and CDS applications."
        Write-Log "Download the Evergreen Bootstrapper from Microsoft and run with: MicrosoftEdgeWebview2Setup.exe /silent /install"
        Start-Process "https://developer.microsoft.com/en-us/microsoft-edge/webview2/"
        Write-Log "Download page opened in browser."
    }
}

