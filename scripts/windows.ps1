# windows.ps1 - Module 2: Windows Settings step functions

function Invoke-WindowsEnableFirewall {
    Write-Section "Firewall, network profile, and sharing"

    # --- 1. Firewall on for every profile ---
    $profileNames = @("Domain", "Private", "Public")
    foreach ($p in $profileNames) {
        Set-NetFirewallProfile -Profile $p -Enabled True -ErrorAction SilentlyContinue
        $status = (Get-NetFirewallProfile -Profile $p).Enabled
        $level = if ($status) { "OK" } else { "ERROR" }
        Write-Log "Profile $p firewall enabled: $status" $level
    }

    # --- 2. Every active network set to Private ---
    # Public blocks the file/printer sharing a POS network needs. Domain-authenticated
    # networks cannot be re-categorised (Windows owns that classification), so those
    # are reported and skipped rather than treated as a failure.
    Write-Log ""
    Write-Log "Setting active networks to the Private profile..."
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    if ($profiles.Count -eq 0) {
        Write-Log "No active network connections found." "WARN"
    }
    foreach ($np in $profiles) {
        if ($np.NetworkCategory -eq 'DomainAuthenticated') {
            Write-Log "'$($np.Name)' is DomainAuthenticated - Windows manages this category, leaving as-is." "WARN"
            continue
        }
        if ($np.NetworkCategory -eq 'Private') {
            Write-Log "'$($np.Name)' is already Private." "OK"
            continue
        }
        try {
            Set-NetConnectionProfile -InterfaceIndex $np.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Write-Log "'$($np.Name)' switched from $($np.NetworkCategory) to Private." "OK"
        } catch {
            Write-Log "Could not set '$($np.Name)' to Private: $($_.Exception.Message)" "WARN"
        }
    }

    # --- 3. File and printer sharing + network discovery, Private profile only ---
    # Scoped to Private so the rules never open up a Public network.
    Write-Log ""
    Write-Log "Enabling file and printer sharing on the Private profile..."
    $groups = @("File and Printer Sharing", "Network Discovery")
    foreach ($g in $groups) {
        try {
            $rules = @(Get-NetFirewallRule -DisplayGroup $g -ErrorAction Stop |
                Where-Object { $_.Profile -match 'Private|Any' })
            if ($rules.Count -eq 0) {
                Write-Log "No Private-profile rules found for '$g'." "WARN"
                continue
            }
            $rules | Enable-NetFirewallRule -ErrorAction SilentlyContinue
            Write-Log "'$g' enabled for Private ($($rules.Count) rule(s))." "OK"
        } catch {
            Write-Log "Could not enable '$g': $($_.Exception.Message)" "WARN"
        }
    }

    # Turn on the sharing feature itself, not just the firewall holes.
    try {
        Set-Service -Name "FDResPub"  -StartupType Automatic -ErrorAction SilentlyContinue
        Set-Service -Name "fdPHost"   -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "FDResPub" -ErrorAction SilentlyContinue
        Start-Service -Name "fdPHost"  -ErrorAction SilentlyContinue
        Write-Log "Function Discovery services set to Automatic and started." "OK"
    } catch {
        Write-Log "Could not configure Function Discovery services: $($_.Exception.Message)" "WARN"
    }

    Write-Log ""
    Write-Log "Firewall and network sharing configuration complete." "OK"
}

function Invoke-WindowsDefaultBrowser {
    Write-Section "Setting Microsoft Edge as the default browser"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "This step requires administrator privileges. Please restart the toolkit as Administrator (right-click Launch.ps1 -> Run as administrator)." "ERROR"
        return
    }

    $edgePaths = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )
    $edge = $edgePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edge) {
        Write-Log "Microsoft Edge was not found on this device. Cannot set it as default." "ERROR"
        return
    }
    Write-Log "Edge found at: $edge"

    # Windows 10/11 protect the per-user default-browser choice with a hashed
    # UserChoice key that cannot be written directly. The supported machine-wide
    # mechanism is a DefaultAssociations XML enforced by policy - it applies at
    # every sign-in and to every user on the device.
    $assetsDir = "C:\Oolio\Assets"
    if (-not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null }
    $xmlPath = Join-Path $assetsDir "DefaultAssociations.xml"

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier="http"   ProgId="MSEdgeHTM" ApplicationName="Microsoft Edge" />
  <Association Identifier="https"  ProgId="MSEdgeHTM" ApplicationName="Microsoft Edge" />
  <Association Identifier=".htm"   ProgId="MSEdgeHTM" ApplicationName="Microsoft Edge" />
  <Association Identifier=".html"  ProgId="MSEdgeHTM" ApplicationName="Microsoft Edge" />
  <Association Identifier=".pdf"   ProgId="MSEdgeHTM" ApplicationName="Microsoft Edge" />
</DefaultAssociations>
"@
    Set-Content -Path $xmlPath -Value $xml -Encoding UTF8 -Force
    Write-Log "Wrote association map: $xmlPath" "OK"

    $sysPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    if (-not (Test-Path $sysPol)) { New-Item -Path $sysPol -Force | Out-Null }
    Set-ItemProperty -Path $sysPol -Name "DefaultAssociationsConfiguration" -Value $xmlPath -Type String -Force
    Write-Log "Policy DefaultAssociationsConfiguration set - enforced at every sign-in." "OK"

    # Also seed the machine defaults so new profiles get Edge without waiting for policy.
    try {
        $dismOut = & dism.exe /Online /Import-DefaultAppAssociations:"$xmlPath" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "DISM default app associations imported for new user profiles." "OK"
        } else {
            Write-Log "DISM import returned exit code $LASTEXITCODE (policy above still applies)." "WARN"
        }
    } catch {
        Write-Log "DISM import failed: $($_.Exception.Message) (policy above still applies)." "WARN"
    }

    # --- Retire Internet Explorer ---
    # Redirect any IE launch into Edge, and disable the optional feature outright.
    $iePol = "HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Main"
    if (-not (Test-Path $iePol)) { New-Item -Path $iePol -Force | Out-Null }
    Set-ItemProperty -Path $iePol -Name "DisableFirstRunCustomize" -Value 1 -Type DWord -Force
    $edgePol = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    if (-not (Test-Path $edgePol)) { New-Item -Path $edgePol -Force | Out-Null }
    # 1 = redirect incompatible IE sites to Edge; keeps IE from ever being the browser.
    Set-ItemProperty -Path $edgePol -Name "InternetExplorerIntegrationLevel"     -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $edgePol -Name "InternetExplorerIntegrationReloadInIEModeAllowed" -Value 0 -Type DWord -Force
    Write-Log "Internet Explorer launches now redirect into Edge." "OK"

    try {
        $ieFeature = Get-WindowsOptionalFeature -Online -FeatureName "Internet-Explorer-Optional-amd64" -ErrorAction SilentlyContinue
        if ($ieFeature -and $ieFeature.State -eq "Enabled") {
            Write-Log "Disabling the Internet Explorer 11 optional feature (no restart)..."
            Disable-WindowsOptionalFeature -Online -FeatureName "Internet-Explorer-Optional-amd64" -NoRestart -ErrorAction Stop | Out-Null
            Write-Log "Internet Explorer 11 feature disabled - takes effect after restart." "OK"
        } else {
            Write-Log "Internet Explorer 11 optional feature is not enabled on this device." "OK"
        }
    } catch {
        Write-Log "Could not disable the IE optional feature: $($_.Exception.Message)" "WARN"
    }

    Write-Log ""
    Write-Log "Edge is now the enforced default browser." "OK"
    Write-Log "The policy applies at next sign-in. The current user's existing choice is replaced then, not immediately." "WARN"
}

function Invoke-WindowsCheckIP {
    Write-Section "Checking network adapter configuration"

    $adapters = Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq "Up" }
    foreach ($adapter in $adapters) {
        Write-Log "Adapter: $($adapter.InterfaceAlias)"
        $ipv4 = $adapter.IPv4Address
        if ($ipv4) {
            Write-Log "  IP Address: $($ipv4.IPAddress)"
            Write-Log "  Prefix Length: $($ipv4.PrefixLength)"
        }
        $dhcp = (Get-NetIPInterface -InterfaceAlias $adapter.InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
        $level = if ($dhcp -eq "Enabled") { "OK" } else { "WARN" }
        Write-Log "  DHCP: $dhcp" $level
    }
}

function Invoke-WindowsSwitchDHCP {
    Write-Section "Switching to DHCP"

    $adapters = Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq "Up" }
    $switched = 0

    foreach ($adapter in $adapters) {
        $iface = $adapter.InterfaceAlias
        $dhcp = (Get-NetIPInterface -InterfaceAlias $iface -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp

        if ($dhcp -eq "Enabled") {
            Write-Log "Adapter '$iface' is already on DHCP. No change needed."
        } else {
            Write-Log "Adapter '$iface' is on static IP. Switching to DHCP..."
            Set-NetIPInterface -InterfaceAlias $iface -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
            Set-DnsClientServerAddress -InterfaceAlias $iface -ResetServerAddresses -ErrorAction SilentlyContinue
            Write-Log "Switched '$iface' to DHCP." "OK"
            Write-Log "Network may drop briefly while acquiring new IP address." "WARN"
            $switched++
        }
    }

    if ($switched -gt 0) {
        Start-Sleep -Seconds 3
        Write-Log "New IP configuration:"
        Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq "Up" } | ForEach-Object {
            Write-Log "  $($_.InterfaceAlias): $($_.IPv4Address.IPAddress)"
        }
    }
}

function Invoke-WindowsCleanDesktop {
    Write-Section "Removing Bepoz apps from desktop, taskbar, and Start menu"

    # Matches a Bepoz shortcut either by its visible name or by where it points.
    # Path matching is what catches renamed shortcuts ("Till", "Back Office").
    $namePattern   = 'bepoz|backoffice|back office|paz|tillpaz'
    $targetPattern = '\\Bepoz\\|\\Bepoz$'

    function Test-IsBepozShortcut {
        param([System.IO.FileInfo]$File, $Shell)

        if ($File.Name -match $namePattern) { return $true }
        if ($File.Extension -ne '.lnk')     { return $false }
        try {
            $lnk = $Shell.CreateShortcut($File.FullName)
            $hay = "$($lnk.TargetPath) $($lnk.WorkingDirectory) $($lnk.Arguments)"
            if ($hay -match $targetPattern)  { return $true }
            if ($hay -match $namePattern)    { return $true }
        } catch {}
        return $false
    }

    $shell   = New-Object -ComObject WScript.Shell
    $removed = 0
    $scanned = 0

    # --- 1. Desktops (current user + public) ---
    $desktops = @(
        "$env:USERPROFILE\Desktop",
        "C:\Users\Public\Desktop"
    )
    foreach ($path in $desktops) {
        if (-not (Test-Path $path)) { continue }
        Write-Log "Scanning desktop: $path"
        foreach ($item in @(Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue)) {
            $scanned++
            if (Test-IsBepozShortcut -File $item -Shell $shell) {
                Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "  Removed: $($item.Name)" "OK"
                $removed++
            }
        }
    }

    # --- 2. Start menu (current user + all users), recursive ---
    $startMenus = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs"
    )
    foreach ($path in $startMenus) {
        if (-not (Test-Path $path)) { continue }
        Write-Log "Scanning Start menu: $path"
        foreach ($item in @(Get-ChildItem -Path $path -File -Recurse -ErrorAction SilentlyContinue)) {
            $scanned++
            if (Test-IsBepozShortcut -File $item -Shell $shell) {
                Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "  Removed: $($item.Name)" "OK"
                $removed++
            }
        }
        # Drop any now-empty Bepoz program folders left behind.
        foreach ($dir in @(Get-ChildItem -Path $path -Directory -Recurse -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match $namePattern })) {
            if (-not (Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "  Removed empty folder: $($dir.Name)" "OK"
            }
        }
    }

    # --- 3. Taskbar pins ---
    # Pinned shortcuts live in the User Pinned\TaskBar folder. Removing the .lnk
    # clears the pin; Explorer also caches the layout in the Taskband key, so that
    # is cleared too and Explorer restarted to force a re-read.
    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    $unpinned = 0
    if (Test-Path $taskbarPath) {
        Write-Log "Scanning taskbar pins: $taskbarPath"
        foreach ($item in @(Get-ChildItem -Path $taskbarPath -File -ErrorAction SilentlyContinue)) {
            $scanned++
            if (Test-IsBepozShortcut -File $item -Shell $shell) {
                Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "  Unpinned: $($item.Name)" "OK"
                $removed++
                $unpinned++
            }
        }
    }

    if ($unpinned -gt 0) {
        $taskband = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        Remove-ItemProperty -Path $taskband -Name "Favorites"       -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $taskband -Name "FavoritesResolve" -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared cached taskbar layout. Restarting Explorer to apply..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Write-Log "Explorer restarted." "OK"
    }

    Write-Log ""
    if ($removed -eq 0) {
        Write-Log "Scanned $scanned item(s). No Bepoz shortcuts found - nothing to remove." "OK"
    } else {
        Write-Log "Scanned $scanned item(s) and removed $removed Bepoz shortcut(s)." "OK"
    }
    Write-Log "Non-Bepoz shortcuts were left untouched." "OK"
    Write-Log "Taskbar and Start menu are cleaned for the user running the toolkit. Re-run under the POS user if that is a different account." "WARN"
}

function Invoke-WindowsSetWallpaper {
    param([string]$toolkitRoot)

    Write-Section "Applying Oolio wallpaper"

    $assetPath  = Join-Path $toolkitRoot "assets\wallpaper.jpg"
    $destFolder = "C:\Oolio\Assets"
    $destPath   = "$destFolder\wallpaper.jpg"

    if (-not (Test-Path $assetPath)) {
        Write-Log "wallpaper.jpg not found at: $assetPath" "ERROR"
        Write-Log "Place wallpaper.jpg in the toolkit assets\ folder and retry." "WARN"
        return
    }

    if (-not (Test-Path $destFolder)) {
        New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
    }

    Copy-Item -Path $assetPath -Destination $destPath -Force
    Write-Log "Wallpaper copied to: $destPath"

    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper      -Value $destPath
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name WallpaperStyle -Value "10"
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name TileWallpaper  -Value "0"

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Wallpaper {
    [DllImport("user32.dll")] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
    [Wallpaper]::SystemParametersInfo(20, 0, $destPath, 3) | Out-Null
    Write-Log "Wallpaper applied." "OK"
}

function Invoke-WindowsActiveHours {
    param([string]$updateHour)

    Write-Section "Configuring Windows Update active hours"

    if (-not $updateHour -or $updateHour.Trim() -eq "") {
        Write-Log "No update hour provided. Defaulting to 3 (3am)." "WARN"
        $updateHour = "3"
    }

    $hour = 0
    if (-not [int]::TryParse($updateHour.Trim(), [ref]$hour)) {
        Write-Log "Update hour '$updateHour' is not a valid number. Cannot configure." "ERROR"
        return
    }
    if ($hour -lt 0 -or $hour -gt 23) {
        Write-Log "Update hour must be 0-23 (got $hour)." "ERROR"
        return
    }

    # Windows enforces a max 18-hour active window, so the inactive (update) window
    # must be at least 6 hours. We centre a 6-hour inactive window on the user's
    # chosen update hour.
    $activeStart = ($hour + 3) % 24
    $activeEnd   = (($hour - 3) + 24) % 24
    $inactiveStart = $activeEnd
    $inactiveEnd   = $activeStart

    Write-Log "Update window centred at ${hour}:00 -> updates may install ${inactiveStart}:00 - ${inactiveEnd}:00 (6 hours)."
    Write-Log "Active hours (no reboots): ${activeStart}:00 - ${activeEnd}:00 (18 hours)."

    # --- Layer 1: Group Policy (locks the values; greys out Settings UI) ---
    $polPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (-not (Test-Path $polPath)) {
        New-Item -Path $polPath -Force | Out-Null
        Write-Log "Created policy key: $polPath"
    }
    Set-ItemProperty -Path $polPath -Name "SetActiveHours"   -Value 1            -Type DWord -Force
    Set-ItemProperty -Path $polPath -Name "ActiveHoursStart" -Value $activeStart -Type DWord -Force
    Set-ItemProperty -Path $polPath -Name "ActiveHoursEnd"   -Value $activeEnd   -Type DWord -Force
    Write-Log "Policy active hours locked: SetActiveHours=1, Start=$activeStart, End=$activeEnd" "OK"

    # --- Clear NoAutoRebootWithLoggedOnUsers so the autologon user does not block reboots ---
    $auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (-not (Test-Path $auPath)) { New-Item -Path $auPath -Force | Out-Null }
    Set-ItemProperty -Path $auPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 0 -Type DWord -Force
    Write-Log "NoAutoRebootWithLoggedOnUsers = 0 (autologon user will not block reboot)" "OK"

    # --- Layer 2: User-settings path (fallback for Home edition where GPO is unenforced) ---
    $uxPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    if (-not (Test-Path $uxPath)) { New-Item -Path $uxPath -Force | Out-Null }
    Set-ItemProperty -Path $uxPath -Name "ActiveHoursStart"      -Value $activeStart -Type DWord -Force
    Set-ItemProperty -Path $uxPath -Name "ActiveHoursEnd"        -Value $activeEnd   -Type DWord -Force
    Set-ItemProperty -Path $uxPath -Name "IsActiveHoursEnabled"  -Value 1            -Type DWord -Force
    Set-ItemProperty -Path $uxPath -Name "SmartActiveHoursState" -Value 0            -Type DWord -Force
    Write-Log "User-settings active hours mirrored: $activeStart - $activeEnd (smart auto-detect disabled)" "OK"

    Write-Log "Configuration complete. Verify in Settings > Windows Update > Update Hours - it should show 'Some settings managed by your organisation'." "OK"
}

function Invoke-WindowsTouchInput {
    Write-Section "Configuring touch keyboard and input settings"

    function Ensure-Path($p) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    }

    $build   = [System.Environment]::OSVersion.Version.Build
    $isWin11 = $build -ge 22000
    Write-Log "Windows build: $build ($( if ($isWin11) { 'Windows 11' } else { 'Windows 10' } ))"

    # Touch keyboard auto-invoke when a text field is tapped.
    $tabletTipPath = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"
    Ensure-Path $tabletTipPath
    Set-ItemProperty -Path $tabletTipPath -Name "EnableAutoInvokeEnabled" -Value 1 -Type DWord -Force
    Write-Log "Touch keyboard auto-invoke enabled (EnableAutoInvokeEnabled=1)" "OK"

    # Touch Keyboard and Handwriting Panel Service - Windows 10 only.
    # On Win11 this service was removed; the functionality is built in.
    $svc = Get-Service -Name "TabletInputService" -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name "TabletInputService" -StartupType Automatic -ErrorAction SilentlyContinue
        if ($svc.Status -ne "Running") {
            Start-Service -Name "TabletInputService" -ErrorAction SilentlyContinue
        }
        $svc   = Get-Service -Name "TabletInputService" -ErrorAction SilentlyContinue
        $level = if ($svc.Status -eq "Running") { "OK" } else { "WARN" }
        Write-Log "TabletInputService: StartupType=Automatic, Status=$($svc.Status)" $level
    } else {
        Write-Log "TabletInputService not present (touch keyboard is built into Windows 11 - no service needed)" "OK"
    }

    # On Windows 10, auto-invoke is more reliable in Tablet Mode.
    # Only enable it if a touch device is actually present.
    if (-not $isWin11) {
        $touchDevices = @(Get-PnpDevice -Class 'HIDClass' -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -match 'touch screen|touch panel|HID-compliant touch' })
        if ($touchDevices.Count -gt 0) {
            Write-Log "Touch device detected: $($touchDevices[0].FriendlyName)"
            Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell"
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell" -Name "TabletMode" -Value 1 -Type DWord -Force
            Write-Log "Tablet Mode enabled - improves touch keyboard auto-invoke reliability on Windows 10" "OK"
        } else {
            Write-Log "No HID touch device detected. Skipping Tablet Mode." "WARN"
        }
    }

    # Disable edge swipe gestures (Action Center swipe-right, Task View swipe-left).
    # On a POS terminal, accidental edge swipes mid-transaction are a nuisance.
    $edgeUiPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"
    Ensure-Path $edgeUiPath
    Set-ItemProperty -Path $edgeUiPath -Name "AllowEdgeSwipe" -Value 0 -Type DWord -Force
    Write-Log "Edge swipe gestures disabled (AllowEdgeSwipe=0)" "OK"
    Write-Log "Action Center (swipe from right) and Task View (swipe from left) are now blocked." "OK"

    # --- Pinch zoom ---
    # Two-finger pinch resizes the POS UI mid-transaction and staff rarely know how
    # to undo it. Blocked at three layers because no single one covers every device:
    #   1. Chrome policy  - stops zoom inside the POS/CDS/KDS pages themselves
    #   2. Precision touchpad - the pinch-to-zoom gesture on laptop-style terminals
    #   3. Wisp touch     - the touchscreen pinch gesture
    Write-Log ""
    Write-Log "Disabling pinch zoom..."

    # 1. Chrome: pin zoom at 100% and stop the user changing it. DefaultZoomLevel 0
    #    is 100%; ZoomLevelsAllowed = 0 removes the zoom controls entirely.
    $chromePol = "HKLM:\SOFTWARE\Policies\Google\Chrome"
    Ensure-Path $chromePol
    Set-ItemProperty -Path $chromePol -Name "DefaultZoomLevel" -Value 0 -Type DWord -Force
    Write-Log "Chrome zoom pinned at 100% (DefaultZoomLevel=0)" "OK"

    # 2. Precision touchpad pinch-to-zoom.
    $ptpPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PrecisionTouchPad"
    if (Test-Path $ptpPath) {
        Set-ItemProperty -Path $ptpPath -Name "ZoomEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Log "Precision touchpad pinch-to-zoom disabled (ZoomEnabled=0)" "OK"
    } else {
        Write-Log "No precision touchpad on this device - skipping touchpad zoom." "OK"
    }

    # 3. Touchscreen pinch. The Wisp zoom value is per-user and read at sign-in.
    $wispTouch = "HKCU:\SOFTWARE\Microsoft\Wisp\Touch"
    Ensure-Path $wispTouch
    Set-ItemProperty -Path $wispTouch -Name "TouchGate"      -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $wispTouch -Name "ZoomEnabled"    -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $wispTouch -Name "PanEnabled"     -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "Touchscreen pinch zoom disabled (panning and tapping still work)" "OK"

    Write-Log ""
    Write-Log "Touch input configuration complete." "OK"
    Write-Log "Sign out and back in (or reboot) for HKCU changes to take effect." "WARN"
    Write-Log "The Oolio shortcuts also pass --disable-pinch to Chrome, which blocks zoom inside the POS itself." "OK"
}

function Invoke-WindowsUsbPower {
    Write-Section "Disabling power saving on USB and serial/COM ports"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "This step requires administrator privileges. Please restart the toolkit as Administrator (right-click Launch.ps1 -> Run as administrator)." "ERROR"
        return
    }

    # 1. Disable "USB selective suspend" in the active power plan (AC + DC).
    #    SUB_USB subgroup GUID and USBSELECTIVESUSPEND setting GUID are stable
    #    across Windows 10/11.
    Write-Log "Disabling USB selective suspend in the active power plan..."
    $subUsb    = "2a737441-1930-4402-8d77-b2bebba308a3"
    $usbSusp   = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
    try {
        & powercfg /setacvalueindex SCHEME_CURRENT $subUsb $usbSusp 0 2>&1 | Out-Null
        & powercfg /setdcvalueindex SCHEME_CURRENT $subUsb $usbSusp 0 2>&1 | Out-Null
        & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
        Write-Log "USB selective suspend disabled (plugged in and on battery)." "OK"
    } catch {
        Write-Log "Could not update the power plan: $($_.Exception.Message)" "WARN"
    }

    # 2. Clear "Allow the computer to turn off this device to save power" on every
    #    USB and serial/COM device. This checkbox is exposed through the
    #    MSPower_DeviceEnable WMI class in root\wmi; Enable = $false means the OS
    #    is NOT allowed to power the device down.
    $targetClasses = @('USB', 'Ports')
    $targets = @()
    try {
        $targets = @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $targetClasses -contains $_.Class })
    } catch {
        Write-Log "Could not enumerate PnP devices: $($_.Exception.Message)" "WARN"
    }
    Write-Log "Found $($targets.Count) present USB / serial device(s)."

    # Index target device instance IDs (upper-cased) for fast matching.
    $targetIds = @{}
    foreach ($t in $targets) {
        if ($t.InstanceId) { $targetIds[$t.InstanceId.ToUpper()] = $t.FriendlyName }
    }

    $pmObjects = @()
    try {
        $pmObjects = @(Get-WmiObject -Namespace root\wmi -Class MSPower_DeviceEnable -ErrorAction Stop)
    } catch {
        Write-Log "Could not read device power settings (MSPower_DeviceEnable): $($_.Exception.Message)" "WARN"
    }

    $changed = 0
    foreach ($pm in $pmObjects) {
        # MSPower InstanceName ends with an enumeration suffix like "_0"; strip it
        # to match the PnP InstanceId.
        $inst = ($pm.InstanceName -replace '_\d+$','').ToUpper()
        if ($targetIds.ContainsKey($inst)) {
            $name = $targetIds[$inst]
            if ($pm.Enable -ne $false) {
                try {
                    $pm.Enable = $false
                    $pm.Put() | Out-Null
                    Write-Log "Disabled power-off for: $name" "OK"
                    $changed++
                } catch {
                    Write-Log "Could not update '$name': $($_.Exception.Message)" "WARN"
                }
            }
        }
    }

    if ($pmObjects.Count -eq 0) {
        Write-Log "No power-manageable devices reported. Nothing to change." "WARN"
    } elseif ($changed -eq 0) {
        Write-Log "All USB / serial devices already have power saving disabled." "OK"
    } else {
        Write-Log "Disabled 'allow the computer to turn off this device' on $changed device(s)." "OK"
    }

    Write-Log "USB and serial/COM power saving configuration complete." "OK"
    Write-Log "Newly connected devices inherit the plan-level USB selective suspend setting; re-run this step after adding peripherals to also clear their per-device checkbox." "WARN"
}

function Invoke-WindowsHardenPOS {
    Write-Section "Hardening Windows for POS use"
    Write-Log "Disabling consumer-friendly nags (OneDrive sync prompts, Spotlight, Cortana, news/widgets, Edge first-run, etc.)"

    # Helper to ensure a registry path exists before writing
    function Ensure-Path($p) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    }

    # --- OneDrive sync prompts ---
    Ensure-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableFileSyncNGSC" -Value 1 -Type DWord -Force
    Write-Log "OneDrive sync prompts disabled (DisableFileSyncNGSC=1)" "OK"

    # --- "Let's finish setting up your device" / SCOOBE ---
    Ensure-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement" -Name "ScoobeSystemSettingEnabled" -Value 0 -Type DWord -Force
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement" -Name "ScoobeSystemSettingEnabled" -Value 0 -Type DWord -Force
    Write-Log "SCOOBE 'finish setting up your device' prompts disabled" "OK"

    # --- Windows Spotlight + Start menu suggestions + lock screen content ---
    $cdm = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    Ensure-Path $cdm
    $cdmKeys = @(
        "SubscribedContent-310093Enabled",
        "SubscribedContent-338387Enabled",
        "SubscribedContent-338388Enabled",
        "SubscribedContent-338389Enabled",
        "SubscribedContent-338393Enabled",
        "SubscribedContent-353694Enabled",
        "SubscribedContent-353696Enabled",
        "SubscribedContent-353698Enabled",
        "SystemPaneSuggestionsEnabled",
        "SilentInstalledAppsEnabled",
        "OEMPreInstalledAppsEnabled",
        "PreInstalledAppsEnabled",
        "PreInstalledAppsEverEnabled",
        "SoftLandingEnabled",
        "RotatingLockScreenEnabled",
        "RotatingLockScreenOverlayEnabled"
    )
    foreach ($name in $cdmKeys) {
        Set-ItemProperty -Path $cdm -Name $name -Value 0 -Type DWord -Force
    }
    Write-Log "Windows Spotlight + Start menu suggestions + lock screen rotating content disabled ($($cdmKeys.Count) keys)" "OK"

    # --- Cortana / search-box web search ---
    $sp = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    Ensure-Path $sp
    Set-ItemProperty -Path $sp -Name "AllowCortana"          -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $sp -Name "DisableWebSearch"      -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $sp -Name "ConnectedSearchUseWeb" -Value 0 -Type DWord -Force
    Write-Log "Cortana and search-box web results disabled" "OK"

    # --- News and interests / Widgets on taskbar ---
    Ensure-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" -Name "EnableFeeds" -Value 0 -Type DWord -Force
    Ensure-Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -Type DWord -Force
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds" -Name "ShellFeedsTaskbarViewMode" -Value 2 -Type DWord -Force
    Write-Log "News and interests / Widgets disabled (taskbar + policy)" "OK"

    # --- Edge first-run experience ---
    Ensure-Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "HideFirstRunExperience" -Value 1 -Type DWord -Force
    Write-Log "Edge first-run experience hidden" "OK"

    # --- Microsoft Account sign-in nag ---
    Ensure-Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Settings"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Settings" -Name "AllowYourAccount" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "Microsoft Account sign-in nag disabled where supported" "OK"

    # --- Sync provider / OneDrive ad in File Explorer ---
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSyncProviderNotifications" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "File Explorer sync-provider ads disabled" "OK"

    Write-Log "POS hardening complete. Most changes apply at next sign-in; News/Widgets and Spotlight changes apply immediately." "WARN"
    Write-Log "Note: HKCU keys apply to the user that ran the toolkit. If the autologon POS user is a different account, re-run this step under that user." "WARN"
}
