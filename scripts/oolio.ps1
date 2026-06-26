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
    Write-Section "Creating Oolio POS Chrome kiosk shortcut"

    $chromePath = Get-ChromePath
    if (-not $chromePath) {
        Write-Log "Chrome not found. Install Chrome in the dependencies module first." "ERROR"
        return
    }

    $shortcutPath = "C:\Users\Public\Desktop\Oolio POS.lnk"
    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath  = $chromePath
    $shortcut.Arguments   = "--kiosk https://pos.oolio.io --no-first-run --disable-infobars"
    $shortcut.WindowStyle = 3
    $shortcut.Save()

    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches pos.oolio.io in fullscreen kiosk mode."
}

function Invoke-OolioInstallCDSChrome {
    Write-Section "Creating Oolio CDS Chrome kiosk shortcut"

    $chromePath = Get-ChromePath
    if (-not $chromePath) {
        Write-Log "Chrome not found. Install Chrome in the dependencies module first." "ERROR"
        return
    }

    # Detect the primary display's actual right edge so the CDS window lands on
    # display #2 regardless of resolution. Falls back to 1920 if WinForms can't
    # load (rare on a POS terminal but possible on Server Core).
    $offsetX = 1920
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $offsetX = $primary.X + $primary.Width
        Write-Log "Primary display: $($primary.Width) x $($primary.Height). Second display origin assumed at X=$offsetX." "OK"
        $screens = [System.Windows.Forms.Screen]::AllScreens
        Write-Log "Detected $($screens.Count) display(s)."
        if ($screens.Count -lt 2) {
            Write-Log "Only one display detected. CDS shortcut will still be created but will appear off-screen until a second display is connected." "WARN"
        }
    } catch {
        Write-Log "Could not query display layout - defaulting to X=$offsetX. $($_.Exception.Message)" "WARN"
    }

    $shortcutPath = "C:\Users\Public\Desktop\Oolio CDS.lnk"
    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath  = $chromePath
    $shortcut.Arguments   = "--kiosk https://cds.oolio.io --no-first-run --disable-infobars --window-position=$offsetX,0"
    $shortcut.WindowStyle = 3
    $shortcut.Save()

    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches cds.oolio.io fullscreen on the display at X=$offsetX."
}

function Invoke-OolioInstallKDSChrome {
    Write-Section "Creating Oolio KDS Chrome app shortcut"

    $chromePath = Get-ChromePath
    if (-not $chromePath) {
        Write-Log "Chrome not found. Install Chrome in the dependencies module first." "ERROR"
        return
    }

    $shortcutPath = "C:\Users\Public\Desktop\Oolio KDS.lnk"
    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath  = $chromePath
    # --app runs kds.oolio.io as a standalone "installed app" window (no tabs/omnibox);
    # --start-fullscreen opens it fullscreen. Differs from POS/CDS which use --kiosk.
    $shortcut.Arguments   = "--app=https://kds.oolio.io --start-fullscreen --no-first-run --disable-infobars"
    $shortcut.WindowStyle = 3
    $shortcut.Save()

    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches kds.oolio.io as a fullscreen Chrome app window."
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
