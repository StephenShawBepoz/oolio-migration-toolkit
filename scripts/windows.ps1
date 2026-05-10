# windows.ps1 - Module 2: Windows Settings step functions

function Invoke-WindowsVerifyAutologon {
    param(
        [string]$username = "",
        [string]$password = "",
        [string]$domain   = ""
    )

    Write-Section "Verifying autologon configuration"

    $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $autoAdmin     = (Get-ItemProperty -Path $winlogonPath -Name AutoAdminLogon    -ErrorAction SilentlyContinue).AutoAdminLogon
    $defaultUser   = (Get-ItemProperty -Path $winlogonPath -Name DefaultUserName   -ErrorAction SilentlyContinue).DefaultUserName
    $defaultDomain = (Get-ItemProperty -Path $winlogonPath -Name DefaultDomainName -ErrorAction SilentlyContinue).DefaultDomainName

    Write-Log "Current AutoAdminLogon:  $autoAdmin"
    Write-Log "Current DefaultUserName: $defaultUser"
    Write-Log "Current DefaultDomainName: $defaultDomain"

    $hasInputs = ($username -and $username.Trim()) -or ($password -and $password.Trim()) -or ($domain -and $domain.Trim())

    if ($autoAdmin -eq "1" -and -not $hasInputs) {
        Write-Log "Autologon is active. Terminal will boot directly to user: $defaultUser" "OK"
        return
    }

    if ($autoAdmin -ne "1") {
        Write-Log "Autologon is NOT active. Terminal will show the login screen on reboot." "WARN"
    }

    if (-not $hasInputs) {
        Write-Log "Fill in Username and Password (and optionally Domain) in the form, then run again to enable autologon." "WARN"
        return
    }

    if (-not $username -or -not $username.Trim()) {
        Write-Log "Username is required to enable autologon." "ERROR"
        return
    }
    if (-not $password) {
        Write-Log "Password is required to enable autologon." "ERROR"
        return
    }

    Write-Log "Enabling autologon for user: $username"
    Set-ItemProperty -Path $winlogonPath -Name AutoAdminLogon  -Value "1"     -Force
    Set-ItemProperty -Path $winlogonPath -Name DefaultUserName -Value $username -Force
    Set-ItemProperty -Path $winlogonPath -Name DefaultPassword -Value $password -Force
    if ($domain -and $domain.Trim()) {
        Set-ItemProperty -Path $winlogonPath -Name DefaultDomainName -Value $domain.Trim() -Force
    } else {
        Set-ItemProperty -Path $winlogonPath -Name DefaultDomainName -Value $env:COMPUTERNAME -Force
    }

    Write-Log "Autologon registry values written." "OK"
    Write-Log "Note: DefaultPassword is stored in plaintext at $winlogonPath - this is the standard AutoAdminLogon mechanism." "WARN"
    Write-Log "Effective after the final restart at the end of the toolkit."
}

function Invoke-WindowsEnableFirewall {
    Write-Section "Enabling Windows Firewall"

    $profileNames = @("Domain", "Private", "Public")
    foreach ($p in $profileNames) {
        Set-NetFirewallProfile -Profile $p -Enabled True -ErrorAction SilentlyContinue
        $status = (Get-NetFirewallProfile -Profile $p).Enabled
        $level = if ($status) { "OK" } else { "ERROR" }
        Write-Log "Profile $p firewall enabled: $status" $level
    }
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

function Invoke-WindowsRenameDevice {
    param([string]$terminalName)

    Write-Section "Renaming device"

    if (-not $terminalName -or $terminalName.Trim() -eq "") {
        Write-Log "No terminal name provided. Cannot rename." "ERROR"
        return
    }

    # Sanitise input - alphanumeric and hyphens only, max 12 chars for the suffix
    $clean = $terminalName.Trim() -replace '[^a-zA-Z0-9\-]', ''
    if ($clean.Length -gt 12) { $clean = $clean.Substring(0, 12) }

    if ($clean.Length -eq 0) {
        Write-Log "Sanitised name is empty. Provide alphanumeric characters." "ERROR"
        return
    }

    $newName = "Oolio-$clean"
    $currentName = $env:COMPUTERNAME

    Write-Log "Current device name: $currentName"
    Write-Log "New device name: $newName"

    if ($currentName -eq $newName) {
        Write-Log "Device is already named $newName. No change needed." "OK"
        return
    }

    Rename-Computer -NewName $newName -Force -ErrorAction Stop
    Write-Log "Device renamed to $newName." "OK"
    Write-Log "This change will take effect after the final restart at the end of the toolkit." "WARN"
}

function Invoke-WindowsCleanDesktop {
    Write-Section "Cleaning desktop"

    $paths = @(
        "$env:USERPROFILE\Desktop",
        "C:\Users\Public\Desktop"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            $items = @(Get-ChildItem -Path $path)
            Write-Log "Found $($items.Count) item(s) in $path"
            foreach ($item in $items) { Write-Log "  Removing: $($item.Name)" }
            Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared: $path" "OK"
        }
    }
    Write-Log "Desktop cleanup complete." "OK"
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
