# oolio.ps1 - Module 4: Oolio POS setup step functions

function Invoke-OolioCreateFolders {
    Write-Section "Creating Oolio folder structure"

    $folders = @("C:\Oolio", "C:\Oolio\Assets", "C:\Oolio\Certs", "C:\Oolio\Logs")
    foreach ($folder in $folders) {
        if (Test-Path $folder) {
            Write-Log "Already exists: $folder"
        } else {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Write-Log "Created: $folder" "OK"
        }
    }
}

function Get-ChromePath {
    $p1 = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    $p2 = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    if (Test-Path $p1) { return $p1 }
    if (Test-Path $p2) { return $p2 }
    return $null
}

function Invoke-OolioInstallPOSChrome {
    Write-Section "Creating Oolio POS Chrome shortcut"

    $chromePath = Get-ChromePath
    if (-not $chromePath) {
        Write-Log "Chrome not found. Install Google Chrome on this device, then re-run this step." "ERROR"
        return
    }

    $assetsDir = "C:\Oolio\Assets"
    if (-not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null }

    $iconPath = Join-Path $assetsDir "pos-icon.ico"
    $iconSet  = $false
    if (Invoke-DownloadWithHeartbeat -Url "https://pos.oolio.io/favicon.ico" -OutFile $iconPath -ProgressLabel "Downloading POS icon") {
        Write-Log "Downloaded icon: $iconPath" "OK"
        $iconSet = $true
    } else {
        Write-Log "Could not download POS favicon - shortcut will use Chrome default icon." "WARN"
    }

    $shortcutPath = "C:\Users\Public\Desktop\Oolio POS.lnk"
    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath  = $chromePath
    $shortcut.Arguments   = "--app=https://pos.oolio.io --start-fullscreen --no-first-run --disable-infobars"
    $shortcut.WindowStyle = 3
    if ($iconSet) { $shortcut.IconLocation = "$iconPath,0" }
    $shortcut.Save()

    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches pos.oolio.io fullscreen (app mode). Exit: Windows key or Alt+F4."
}

function Invoke-OolioInstallCDSChrome {
    Write-Section "Creating Oolio CDS Chrome shortcut"

    $chromePath = Get-ChromePath
    if (-not $chromePath) {
        Write-Log "Chrome not found. Install Google Chrome on this device, then re-run this step." "ERROR"
        return
    }

    $assetsDir = "C:\Oolio\Assets"
    if (-not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null }

    $iconPath = Join-Path $assetsDir "cds-icon.ico"
    $iconSet  = $false
    if (Invoke-DownloadWithHeartbeat -Url "https://cds.oolio.io/favicon.ico" -OutFile $iconPath -ProgressLabel "Downloading CDS icon") {
        Write-Log "Downloaded icon: $iconPath" "OK"
        $iconSet = $true
    } else {
        Write-Log "Could not download CDS favicon - shortcut will use Chrome default icon." "WARN"
    }

    $shortcutPath = "C:\Users\Public\Desktop\Oolio CDS.lnk"
    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath  = $chromePath
    # --window-position=1920,0 places it on the second display assuming 1920px primary
    $shortcut.Arguments   = "--app=https://cds.oolio.io --start-fullscreen --no-first-run --disable-infobars --window-position=1920,0"
    $shortcut.WindowStyle = 3
    if ($iconSet) { $shortcut.IconLocation = "$iconPath,0" }
    $shortcut.Save()

    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches cds.oolio.io fullscreen on second display (assumes 1920px primary)." "WARN"
    Write-Log "If primary display is not 1920px wide, update the --window-position X value in the shortcut manually."
}

function Invoke-OolioInstallKDSChrome {
    Write-Section "Creating Oolio KDS Chrome shortcut"

    $chromePath = Get-ChromePath
    if (-not $chromePath) {
        Write-Log "Chrome not found. Install Google Chrome on this device, then re-run this step." "ERROR"
        return
    }

    $assetsDir = "C:\Oolio\Assets"
    if (-not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null }

    $iconPath = Join-Path $assetsDir "kds-icon.ico"
    $iconSet  = $false
    if (Invoke-DownloadWithHeartbeat -Url "https://kds.oolio.io/favicon.ico" -OutFile $iconPath -ProgressLabel "Downloading KDS icon") {
        Write-Log "Downloaded icon: $iconPath" "OK"
        $iconSet = $true
    } else {
        Write-Log "Could not download KDS favicon - shortcut will use Chrome default icon." "WARN"
    }

    $shortcutPath = "C:\Users\Public\Desktop\Oolio KDS.lnk"
    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath  = $chromePath
    $shortcut.Arguments   = "--app=https://kds.oolio.io --start-fullscreen --no-first-run --disable-infobars"
    $shortcut.WindowStyle = 3
    if ($iconSet) { $shortcut.IconLocation = "$iconPath,0" }
    $shortcut.Save()

    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches kds.oolio.io fullscreen (app mode). Exit: Windows key or Alt+F4."
}

function Invoke-OolioSetStartup {
    Write-Section "Configuring startup via shell:startup"

    $startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    if (-not (Test-Path $startupFolder)) {
        New-Item -ItemType Directory -Path $startupFolder -Force | Out-Null
    }

    $copied = 0
    foreach ($name in @("Oolio POS.lnk", "Oolio CDS.lnk", "Oolio KDS.lnk")) {
        $src = Join-Path "C:\Users\Public\Desktop" $name
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination (Join-Path $startupFolder $name) -Force
            Write-Log "Copied to shell:startup: $startupFolder\$name" "OK"
            $copied++
        }
    }

    if ($copied -eq 0) {
        Write-Log "No Oolio desktop shortcuts found to copy." "ERROR"
        Write-Log "Run the install-pos-chrome / install-cds-chrome steps first." "WARN"
        return
    }

    Write-Log "Oolio will launch automatically when the autologon user signs in."

    # Tidy up any legacy HKCU Run entries from previous toolkit versions.
    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    foreach ($name in @("OolioPOS", "OolioKDS")) {
        $existing = (Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue).$name
        if ($existing) {
            Remove-ItemProperty -Path $runPath -Name $name -Force -ErrorAction SilentlyContinue
            Write-Log "Removed legacy HKCU Run entry: $name" "OK"
        }
    }
}

function Invoke-OolioFinalRestart {
    Write-Section "Initiating final restart"
    Write-Log "The following changes require a restart to take effect:"
    Write-Log "  - Device rename to Oolio-[name]"
    Write-Log "  - Wallpaper settings"
    Write-Log "  - Any autologon registry changes"
    Write-Log ""
    Write-Log "Restarting in 30 seconds. Run 'shutdown /a' in a command prompt to cancel."
    shutdown /r /t 30 /c "Oolio migration toolkit - applying final changes"
    Write-Log "Restart scheduled." "OK"
}
