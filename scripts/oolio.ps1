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

function Get-OolioPosExePath {
    # Resolve the installed Oolio POS executable from the uninstall registry
    # (written by the electron-builder NSIS installer). Tries DisplayIcon first
    # (points straight at the exe), then scans InstallLocation for the main exe.
    $entries = Get-InstalledProgram -NameLike "*Oolio*POS*"
    if (-not $entries -or $entries.Count -eq 0) { $entries = Get-InstalledProgram -NameLike "*Oolio*" }

    foreach ($e in $entries) {
        $props = Get-ItemProperty -Path $e.RegistryPath -ErrorAction SilentlyContinue

        # DisplayIcon is usually "C:\Program Files\Oolio POS\Oolio POS.exe",0
        $icon = $props.DisplayIcon
        if ($icon) {
            $iconPath = $icon.Split(',')[0].Trim().Trim('"')
            if ($iconPath -and (Test-Path $iconPath) -and $iconPath.ToLower().EndsWith(".exe") -and ((Split-Path $iconPath -Leaf) -notlike "*Uninstall*")) {
                return $iconPath
            }
        }

        # Fall back to the largest top-level exe in InstallLocation, skipping the uninstaller.
        $loc = $props.InstallLocation
        if ($loc -and (Test-Path $loc)) {
            $exe = Get-ChildItem -Path $loc -Filter "*.exe" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike "Uninstall*" } |
                Sort-Object Length -Descending | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

function Invoke-OolioInstallPOSApp {
    param([string]$toolkitRoot)

    Write-Section "Installing Oolio POS (native Windows app)"

    if (-not $toolkitRoot) { $toolkitRoot = (Resolve-Path "$PSScriptRoot\..").Path }
    $installerDir = Join-Path $toolkitRoot "installers"

    if (-not (Test-Path $installerDir)) {
        New-Item -ItemType Directory -Path $installerDir -Force | Out-Null
        Write-Log "Created installers folder: $installerDir"
    }

    # Pick the newest POS installer (by write time). Falls back to any .exe.
    $candidates = @(Get-ChildItem -Path $installerDir -Filter "POS-*installer.exe" -File -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        $candidates = @(Get-ChildItem -Path $installerDir -Filter "*.exe" -File -ErrorAction SilentlyContinue)
    }
    if ($candidates.Count -eq 0) {
        # The installer is ~35 MB and is deliberately not shipped with the toolkit -
        # only Windows-app deployments need it. This is a setup step for the
        # technician, not a toolkit fault.
        Write-Log "No Oolio POS installer found in: $installerDir" "ERROR"
        Write-Log "" "WARN"
        Write-Log "The POS installer is not bundled with the toolkit (it is ~35 MB and only" "WARN"
        Write-Log "Windows-app deployments need it). To continue:" "WARN"
        Write-Log "  1. Get the current POS build (POS-*-installer.exe) from the Oolio Platform" "WARN"
        Write-Log "     team, or copy it from another terminal's C:\OolioMigration\installers\." "WARN"
        Write-Log "  2. Copy it into: $installerDir" "WARN"
        Write-Log "  3. Re-run this step." "WARN"
        Write-Log "" "WARN"
        Write-Log "If this venue is a Chrome deployment, this step does not apply - change the" "WARN"
        Write-Log "deployment mode in the Deployment options step, or skip this step." "WARN"
        return
    }

    $installer = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Log "Installer: $($installer.Name)"
    Write-Log "Size: $([math]::Round($installer.Length / 1MB, 1)) MB"

    # --- Signature check (advisory for a locally-supplied installer) ---
    try {
        $sig = Get-AuthenticodeSignature -FilePath $installer.FullName -ErrorAction Stop
        $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "(unsigned)" }
        if ($sig.Status -eq 'Valid') {
            Write-Log "Authenticode signature: Valid - $subject" "OK"
        } else {
            Write-Log "Authenticode signature status: $($sig.Status) - $subject" "WARN"
            Write-Log "Proceeding because this installer was supplied locally in the toolkit. Verify its source if you did not place it there yourself." "WARN"
        }
    } catch {
        Write-Log "Could not read signature: $($_.Exception.Message)" "WARN"
    }

    # --- Idempotency: report an existing install; the installer will upgrade in place ---
    $existing = @(Get-InstalledProgram -NameLike "*Oolio*POS*")
    if ($existing.Count -eq 0) { $existing = @(Get-InstalledProgram -NameLike "*Oolio*") }
    if ($existing.Count -gt 0) {
        Write-Log "Existing install detected: $($existing[0].DisplayName) $($existing[0].DisplayVersion). The installer will upgrade/repair in place." "WARN"
    }

    # --- Run the electron-builder NSIS installer silently ---
    # /S = silent. The installer is perMachine (its manifest requires admin), so it
    # installs to Program Files for all users. (/allusers is ignored under /S, so we
    # rely on the perMachine build rather than passing it.)
    Write-Log "Running installer silently (/S). Installs per-machine to Program Files; this can take a minute..."
    $proc = Start-Process -FilePath $installer.FullName -ArgumentList "/S" -PassThru
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing Oolio POS"

    if ($proc.ExitCode -ne 0) {
        Write-Log "Installer exited with code $($proc.ExitCode)." "ERROR"
        Write-Log "Run $($installer.Name) manually (double-click) to see the GUI error." "WARN"
        return
    }
    Write-Log "Installer exited cleanly (code 0)." "OK"

    # --- Resolve the installed app exe ---
    $exePath = Get-OolioPosExePath
    if (-not $exePath) {
        Write-Log "Install reported success but the Oolio POS executable could not be located from the uninstall registry." "WARN"
        Write-Log "Check Program Files for the Oolio POS folder, then create the startup shortcut manually." "WARN"
        return
    }
    Write-Log "Oolio POS executable: $exePath" "OK"
    $ver = (Get-Item $exePath).VersionInfo.FileVersion
    if ($ver) { Write-Log "Installed file version: $ver" }

    # --- Drop a Public-Desktop shortcut named "Oolio POS.lnk" so the existing
    #     'Configure startup' step copies it into shell:startup unchanged. This is
    #     the same shortcut name the Chrome-kiosk path uses, so set-startup needs
    #     no branching for native vs Chrome. ---
    $shortcutPath = "C:\Users\Public\Desktop\Oolio POS.lnk"
    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath       = $exePath
    $shortcut.WorkingDirectory = Split-Path $exePath -Parent
    $shortcut.WindowStyle      = 3   # maximised
    $shortcut.Save()
    Write-Log "Shortcut created: $shortcutPath -> $exePath" "OK"
    Write-Log "The native app manages its own fullscreen window - no Chrome kiosk flags are used."
    Write-Log "Next: run 'Configure startup' to copy this shortcut into shell:startup so the POS launches at login."
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
