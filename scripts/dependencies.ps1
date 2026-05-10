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

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Log "Source: $msiUrl"
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
        $size = [math]::Round((Get-Item $msiPath).Length / 1MB, 1)
        Write-Log "Downloaded: $size MB to $msiPath" "OK"
    } catch {
        Write-Log "Failed to download Chrome MSI: $($_.Exception.Message)" "ERROR"
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    Write-Log "Installing silently (msiexec /i /qn /norestart)..."
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "`"$msiPath`"", "/qn", "/norestart") -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -eq 0) {
        Write-Log "Chrome installed successfully." "OK"
        if (Test-Path $chromePath) {
            $ver = (Get-Item $chromePath).VersionInfo.FileVersion
            Write-Log "Verified: $chromePath version $ver" "OK"
        }
    } else {
        Write-Log "msiexec exited with code $($proc.ExitCode)." "ERROR"
    }

    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
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

