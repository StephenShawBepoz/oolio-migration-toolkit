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
