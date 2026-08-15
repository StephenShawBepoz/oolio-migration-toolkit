# router.ps1 - maps incoming module + step IDs to PowerShell function names

function Get-StepFunctionName {
    param([string]$ModuleId, [string]$StepId)

    $map = @{
        "system" = @{
            "check-hardware" = "Invoke-SystemCheckHardware"
        }
        "bepoz" = @{
            "read-registry"        = "Invoke-BepozReadRegistry"
            "terminate-processes"  = "Invoke-BepozTerminateProcesses"
            "stop-sql"             = "Invoke-BepozStopSQL"
            "zip-data"             = "Invoke-BepozZipData"
            "clear-startup"        = "Invoke-BepozClearStartup"
            "check-run-key"        = "Invoke-BepozCheckRunKey"
            "delete-registry"      = "Invoke-BepozDeleteRegistry"
            "consolidate-backups"  = "Invoke-BepozConsolidateBackups"
        }
        "windows" = @{
            "default-browser"  = "Invoke-WindowsDefaultBrowser"
            "usb-power"        = "Invoke-WindowsUsbPower"
            "enable-firewall"  = "Invoke-WindowsEnableFirewall"
            "active-hours"     = "Invoke-WindowsActiveHours"
            "harden-pos"       = "Invoke-WindowsHardenPOS"
            "touch-pos"             = "Invoke-WindowsTouchPOS"
            "disable-multitouch"    = "Invoke-WindowsDisableMultitouch"
            "power-plan"            = "Invoke-WindowsPowerPlan"
            "disable-distractions"  = "Invoke-WindowsDisableDistractions"
            "check-ip"         = "Invoke-WindowsCheckIP"
            "switch-dhcp"      = "Invoke-WindowsSwitchDHCP"
            "clean-desktop"    = "Invoke-WindowsCleanDesktop"
            "set-wallpaper"    = "Invoke-WindowsSetWallpaper"
        }
        "dependencies" = @{
            "check-epsonnet-config" = "Invoke-DepsCheckEpsonNetConfig"
            "check-webview2"   = "Invoke-DepsCheckWebView2"
            "teamviewer"       = "Invoke-DepsInstallTeamViewer"
        }
        "oolio" = @{
            "create-folders"     = "Invoke-OolioCreateFolders"
            "install-pos-app"    = "Invoke-OolioInstallPOSApp"
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
