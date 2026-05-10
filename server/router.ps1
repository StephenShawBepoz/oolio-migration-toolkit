# router.ps1 - maps incoming module + step IDs to PowerShell function names

function Get-StepFunctionName {
    param([string]$ModuleId, [string]$StepId)

    $map = @{
        "bepoz" = @{
            "read-registry"   = "Invoke-BepozReadRegistry"
            "stop-sql"        = "Invoke-BepozStopSQL"
            "zip-data"        = "Invoke-BepozZipData"
            "kill-processes"  = "Invoke-BepozKillProcesses"
            "clear-startup"   = "Invoke-BepozClearStartup"
            "check-run-key"   = "Invoke-BepozCheckRunKey"
            "delete-registry" = "Invoke-BepozDeleteRegistry"
            "uninstall"       = "Invoke-BepozUninstall"
        }
        "windows" = @{
            "verify-autologon" = "Invoke-WindowsVerifyAutologon"
            "enable-firewall"  = "Invoke-WindowsEnableFirewall"
            "check-ip"         = "Invoke-WindowsCheckIP"
            "switch-dhcp"      = "Invoke-WindowsSwitchDHCP"
            "rename-device"    = "Invoke-WindowsRenameDevice"
            "clean-desktop"    = "Invoke-WindowsCleanDesktop"
            "set-wallpaper"    = "Invoke-WindowsSetWallpaper"
        }
        "dependencies" = @{
            "check-chrome"   = "Invoke-DepsCheckChrome"
            "check-webview2" = "Invoke-DepsCheckWebView2"
        }
        "oolio" = @{
            "create-folders"     = "Invoke-OolioCreateFolders"
            "install-pos-chrome" = "Invoke-OolioInstallPOSChrome"
            "install-cds-chrome" = "Invoke-OolioInstallCDSChrome"
            "install-kds-chrome" = "Invoke-OolioInstallKDSChrome"
            "set-startup"        = "Invoke-OolioSetStartup"
            "final-restart"      = "Invoke-OolioFinalRestart"
        }
    }

    if (-not $map.ContainsKey($ModuleId)) { return $null }
    if (-not $map[$ModuleId].ContainsKey($StepId)) { return $null }
    return $map[$ModuleId][$StepId]
}
