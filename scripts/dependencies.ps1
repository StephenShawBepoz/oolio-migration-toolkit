# dependencies.ps1 - Module 3: Oolio Dependencies step functions

function Invoke-DepsCheckChrome {
    Write-Section "Checking Google Chrome"

    $chromePath    = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    $chromePathx86 = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"

    if (Test-Path $chromePath) {
        $ver = (Get-Item $chromePath).VersionInfo.FileVersion
        Write-Log "Chrome found at: $chromePath" "OK"
        Write-Log "Version: $ver"
    } elseif (Test-Path $chromePathx86) {
        $ver = (Get-Item $chromePathx86).VersionInfo.FileVersion
        Write-Log "Chrome found at: $chromePathx86" "OK"
        Write-Log "Version: $ver"
    } else {
        Write-Log "Chrome not found on this terminal." "WARN"
        Write-Log "Download and install Chrome before running Chrome-mode deployments."
        Start-Process "https://www.google.com/chrome/"
        Write-Log "Chrome download page opened in browser."
    }
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

function Invoke-DepsInstallCerts {
    param([string]$toolkitRoot)

    Write-Section "Installing Epson TLS certificates"

    $certsFolder = Join-Path $toolkitRoot "certs"

    if (-not (Test-Path $certsFolder)) {
        Write-Log "Certs folder not found at: $certsFolder" "ERROR"
        return
    }

    $certs = @(Get-ChildItem -Path $certsFolder -Filter "*.cer")

    if ($certs.Count -eq 0) {
        Write-Log "No .cer files found in certs folder." "WARN"
        Write-Log "Generate certificates via the Epson printer web interface and place them in the certs\ folder."
        return
    }

    Write-Log "Found $($certs.Count) certificate(s) to install."

    foreach ($cert in $certs) {
        Write-Log "Installing: $($cert.Name)"
        $result = certutil -addstore "Root" $cert.FullName 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Installed: $($cert.Name)" "OK"
        } else {
            Write-Log "Failed to install: $($cert.Name) - $result" "ERROR"
        }
    }

    Write-Log "Verifying installed certificates..."
    $verify = certutil -store Root 2>&1 | Select-String -Pattern "epson" -CaseSensitive:$false
    if ($verify) {
        Write-Log "Epson certificate(s) confirmed in Root store." "OK"
        $verify | ForEach-Object { Write-Log "  $_" }
    } else {
        Write-Log "No Epson certificates found in Root store after installation. Check output above." "WARN"
    }
}
