# windows.ps1 - Module 2: Windows Settings step functions

function Invoke-WindowsCheckJoin {
    Write-Section "Detecting domain / Azure AD join state"

    # AD join: Win32_ComputerSystem.PartOfDomain. AAD join: dsregcmd /status.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $adJoined = $false
    if ($cs) {
        $adJoined = [bool]$cs.PartOfDomain
        Write-Log "Computer name: $($cs.Name)"
        Write-Log "Workgroup / Domain: $($cs.Domain)"
        Write-Log "PartOfDomain (AD): $adJoined"
    }

    $aadJoined        = $false
    $domainJoined     = $false
    $workplaceJoined  = $false
    try {
        $dsreg = & dsregcmd /status 2>&1 | Out-String
        foreach ($line in ($dsreg -split "`r?`n")) {
            if ($line -match 'AzureAdJoined\s*:\s*(YES|NO)')   { $aadJoined       = ($matches[1] -eq 'YES') }
            if ($line -match 'DomainJoined\s*:\s*(YES|NO)')    { $domainJoined    = ($matches[1] -eq 'YES') }
            if ($line -match 'WorkplaceJoined\s*:\s*(YES|NO)') { $workplaceJoined = ($matches[1] -eq 'YES') }
        }
    } catch {
        Write-Log "dsregcmd not available or failed: $($_.Exception.Message)" "WARN"
    }

    Write-Log "AzureAdJoined:    $aadJoined"
    Write-Log "DomainJoined:     $domainJoined"
    Write-Log "WorkplaceJoined:  $workplaceJoined"

    # Classify the terminal so downstream advice is specific.
    $state = "Standalone / Workgroup"
    if ($adJoined -and $aadJoined)      { $state = "Hybrid AD + Azure AD joined" }
    elseif ($adJoined)                   { $state = "AD domain joined" }
    elseif ($aadJoined)                  { $state = "Azure AD joined" }
    elseif ($workplaceJoined)            { $state = "Workplace joined (registered, not joined)" }

    Write-Log "Terminal state: $state" "OK"

    if ($state -ne "Standalone / Workgroup") {
        Write-Log "Caution: this terminal is managed. The following steps may be controlled by Group Policy or Intune and will be reverted at the next policy refresh:" "WARN"
        Write-Log "  - Autologon (AutoAdminLogon)" "WARN"
        Write-Log "  - Windows Update active hours" "WARN"
        Write-Log "  - Wallpaper / lock screen" "WARN"
        Write-Log "  - Notification / Cortana / news-and-interests policies" "WARN"
        Write-Log "Confirm with the venue / IT contact before proceeding, or expect to repeat these steps after every reboot." "WARN"
    } else {
        Write-Log "Standalone terminal - safe to apply all hardening steps." "OK"
    }
}

function Invoke-WindowsVerifyAutologon {
    # Credentials come from environment variables set by the server when it
    # launches this child process. Keeping them out of the command line means
    # they never appear in Process Explorer, Sysmon, ETW, or event logs.
    $username = $env:OOLIO_AL_USERNAME
    $password = $env:OOLIO_AL_PASSWORD
    $domain   = $env:OOLIO_AL_DOMAIN
    if ($null -eq $username) { $username = "" }
    if ($null -eq $password) { $password = "" }
    if ($null -eq $domain)   { $domain   = "" }

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

function Invoke-WindowsTouchPOS {
    Write-Section "Hardening touch input for POS use"

    function Ensure-Path($p) { if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }

    # --- Touch keyboard auto-popup in desktop mode (so it shows when a text field is focused) ---
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7" -Name "EnableDesktopModeAutoInvoke" -Value 1 -Type DWord -Force
    Write-Log "Touch keyboard auto-popup enabled in desktop mode (EnableDesktopModeAutoInvoke=1)" "OK"

    # --- Disable edge swipes (Action Center, task view, app switcher) ---
    Ensure-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" -Name "AllowEdgeSwipe"     -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" -Name "DisableCharmsHint" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" -Name "DisableTLcorner"   -Value 1 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" -Name "DisableCorners"    -Value 1 -Type DWord -Force
    Write-Log "Edge swipes, charms hint, and hot corners disabled" "OK"

    # --- Force desktop mode (no tablet mode), always boot to desktop ---
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell" -Name "TabletMode"  -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell" -Name "SignInMode"  -Value 1 -Type DWord -Force
    Write-Log "Tablet mode disabled; sign-in always lands in desktop mode" "OK"

    # --- Disable accessibility-key prompts (5x Shift -> Sticky Keys dialog mid-sale, etc.) ---
    Ensure-Path "HKCU:\Control Panel\Accessibility\StickyKeys"
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys"        -Name "Flags" -Value "506" -Force
    Ensure-Path "HKCU:\Control Panel\Accessibility\Keyboard Response"
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "Flags" -Value "122" -Force
    Ensure-Path "HKCU:\Control Panel\Accessibility\ToggleKeys"
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys"        -Name "Flags" -Value "58"  -Force
    Write-Log "Sticky / Filter / Toggle Keys prompts disabled" "OK"

    # --- Disable USB autoplay / autorun ---
    Ensure-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoAutorun"          -Value 1   -Type DWord -Force
    Write-Log "USB autoplay / autorun disabled on all drive types" "OK"

    Write-Log "Touch POS hardening complete. Most changes apply immediately; tablet-mode lock applies at next sign-in." "WARN"
}

function Invoke-WindowsPowerPlan {
    Write-Section "Configuring power plan for always-on POS"

    # Never sleep, never turn off display, on AC. (Battery values set too for hybrid devices.)
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0
    powercfg /change disk-timeout-ac 0
    powercfg /change disk-timeout-dc 0
    Write-Log "Sleep / monitor / hibernate / disk-spindown timeouts set to 0 (never) on AC and DC" "OK"

    # Turn off hibernation entirely - reclaims hiberfil.sys, prevents fast-startup confusion
    powercfg /hibernate off
    Write-Log "Hibernation disabled (hiberfil.sys removed)" "OK"

    # Disable fast startup so reboots are real reboots (kiosk app picks up changes)
    $hiberPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    if (Test-Path $hiberPath) {
        Set-ItemProperty -Path $hiberPath -Name "HiberbootEnabled" -Value 0 -Type DWord -Force
        Write-Log "Fast Startup disabled (HiberbootEnabled=0) so reboots are full restarts" "OK"
    }

    # Disable lid-close action (mostly relevant for laptop POS) - do nothing on close
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 2>$null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 2>$null
    powercfg /setactive SCHEME_CURRENT
    Write-Log "Lid-close action set to 'do nothing'" "OK"

    Write-Log "Power plan configured for 24/7 operation." "OK"
}

function Invoke-WindowsDisableDistractions {
    Write-Section "Disabling notifications, Game Bar, Copilot, Storage Sense"

    function Ensure-Path($p) { if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }

    # --- Toast notifications ---
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications" -Name "ToastEnabled" -Value 0 -Type DWord -Force
    Ensure-Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "DisableNotificationCenter" -Value 1 -Type DWord -Force
    Write-Log "Toast notifications and Notification Center disabled" "OK"

    # --- Focus Assist / Quiet Hours: keep silent ---
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings" -Name "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK"         -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings" -Name "NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "Above-lock-screen toasts disabled" "OK"

    # --- Xbox Game Bar (the Win+G overlay) ---
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\GameBar"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\GameBar" -Name "UseNexusForGameBarEnabled"   -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\GameBar" -Name "ShowStartupPanel"            -Value 0 -Type DWord -Force
    Ensure-Path "HKCU:\System\GameConfigStore"
    Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force
    Ensure-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -Type DWord -Force
    Write-Log "Xbox Game Bar and Game DVR disabled" "OK"

    # --- Windows Copilot ---
    Ensure-Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force
    Ensure-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Copilot"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Copilot" -Name "IsCopilotAvailable" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "Windows Copilot disabled (policy + per-user)" "OK"

    # --- Storage Sense (auto-deletes 'old' files - could nuke Bepoz backup zips) ---
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Name "01" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Ensure-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense" -Name "AllowStorageSenseGlobal" -Value 0 -Type DWord -Force
    Write-Log "Storage Sense disabled (won't auto-delete backup zips)" "OK"

    # --- Taskbar: hide Search box, Task View, Widgets, Meet Now ---
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Ensure-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowTaskViewButton" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa"          -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Ensure-Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start" -Name "HideRecommendedSection" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "Taskbar Search box, Task View button, and Widgets icon hidden" "OK"

    # --- First-sign-in animation ---
    Ensure-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableFirstLogonAnimation" -Value 0 -Type DWord -Force
    Write-Log "First-sign-in animation disabled" "OK"

    Write-Log "Distractions cleanup complete. Taskbar / Copilot / Game Bar changes apply at next sign-in." "WARN"
}

function Invoke-WindowsLocaleTime {
    param([string]$timeZone)

    Write-Section "Configuring locale and time"

    if (-not $timeZone -or $timeZone.Trim() -eq "") {
        Write-Log "No time zone provided. Defaulting to 'AUS Eastern Standard Time' (Sydney/Melbourne)." "WARN"
        $timeZone = "AUS Eastern Standard Time"
    }
    $timeZone = $timeZone.Trim()

    # --- Set time zone ---
    $current = (Get-TimeZone).Id
    Write-Log "Current time zone: $current"
    if ($current -eq $timeZone) {
        Write-Log "Time zone already set to $timeZone." "OK"
    } else {
        try {
            # Capture both stdout and stderr so a bad zone name produces a
            # useful message ("The time zone X was not found.") rather than
            # just an exit code.
            $tzOutput = & tzutil /s "$timeZone" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Time zone set to: $timeZone" "OK"
            } else {
                Write-Log "tzutil exited with code $LASTEXITCODE." "ERROR"
                foreach ($line in @($tzOutput)) {
                    if ($line -and "$line".Trim().Length -gt 0) {
                        Write-Log "  tzutil: $line" "ERROR"
                    }
                }
                Write-Log "Run 'tzutil /l' on the terminal to list valid zone names." "WARN"
                return
            }
        } catch {
            Write-Log "Failed to set time zone: $_" "ERROR"
            return
        }
    }

    # --- Sync time with NTP pool ---
    Write-Log "Configuring NTP source and forcing resync..."
    try {
        $svc = Get-Service -Name "w32time" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Running") {
            Set-Service -Name "w32time" -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name "w32time" -ErrorAction SilentlyContinue
            Write-Log "Started Windows Time service (w32time)" "OK"
        }
        w32tm /config /manualpeerlist:"au.pool.ntp.org,pool.ntp.org,time.windows.com" /syncfromflags:manual /reliable:YES /update | Out-Null
        w32tm /resync /force | Out-Null
        Write-Log "NTP sources set to au.pool.ntp.org + fallbacks; resync forced" "OK"
        $status = w32tm /query /status 2>&1 | Out-String
        Write-Log ("Time status:`n" + $status.Trim())
    } catch {
        Write-Log "Time sync configuration failed: $_" "WARN"
    }

    # --- Locale / region: en-AU, AUD, short-date dd/MM/yyyy ---
    try {
        Set-WinSystemLocale     -SystemLocale en-AU -ErrorAction SilentlyContinue
        Set-WinUserLanguageList -LanguageList en-AU -Force -ErrorAction SilentlyContinue
        Set-WinHomeLocation     -GeoId 12 -ErrorAction SilentlyContinue   # 12 = Australia
        Set-Culture en-AU -ErrorAction SilentlyContinue
        Write-Log "System locale, user language, and culture set to en-AU (GeoId 12)" "OK"
    } catch {
        Write-Log "Locale configuration partial: $_" "WARN"
    }

    Write-Log "Locale and time configured. System locale change requires a restart to fully apply." "WARN"
}
