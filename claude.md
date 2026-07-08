# Oolio Migration Toolkit — Technical Specification
## Claude Code Handoff Document

> **Note (v1.5):** This is the original v1.0 design specification, kept for
> reference. The implementation has since evolved — terminal types (S/ST/T/KDS),
> the migrate flow, native Oolio POS app install, silent dependency installers,
> and more. For current behaviour see `OVERVIEW.md` and `CHANGELOG.md`; the code
> itself is the source of truth.

**Project:** Bepoz to Oolio Platform Migration Toolkit  
**Purpose:** A locally-hosted web toolkit that guides a technician through migrating a Windows POS terminal from Bepoz to the Oolio Platform  
**Author:** Stephen, Head of Onboarding NSW  
**Version:** 1.0 — For development in Claude Code

---

## 1. Overview

A technician copies a single folder to a Windows POS terminal and runs one PowerShell script. That script starts a lightweight HTTP server on localhost and opens a browser to a polished web UI. The technician works through four modules, each containing steps with live script execution, streaming output, and persistent progress tracking across sessions.

The toolkit must work on Windows 10 and Windows 11. No internet connection is required after the folder is copied to the terminal. No installation is required beyond copying the folder.

---

## 2. Folder Structure

```
OolioMigration\
  Launch.ps1                  <- entry point, right-click Run as Administrator
  progress.json               <- auto-created, persists module/step completion state
  server\
    server.ps1                <- HTTP listener, routes requests to module scripts
    router.ps1                <- maps incoming step IDs to the correct module script
  ui\
    index.html                <- single-page app shell
    app.js                    <- all front-end logic
    style.css                 <- all styles
  scripts\
    bepoz.ps1                 <- module 1 step logic
    windows.ps1               <- module 2 step logic
    dependencies.ps1          <- module 3 step logic
    oolio.ps1                 <- module 4 step logic
    shared.ps1                <- shared helper functions used across modules
  assets\
    wallpaper.jpg             <- technician drops Oolio wallpaper here before running
    README.txt                <- brief note: drop wallpaper.jpg and cert files here
  certs\
    README.txt                <- brief note: drop .cer files here before running module 3
```

---

## 3. Launch.ps1 — Entry Point

This script is what the technician runs. It must:

1. Check it is running as Administrator. If not, relaunch itself elevated using `Start-Process powershell -Verb RunAs`.
2. Set the PowerShell execution policy to `Bypass` for the current process only.
3. Start `server\server.ps1` as a background job.
4. Wait up to 3 seconds for the server to be ready by polling `http://localhost:8080/ping`.
5. Open `http://localhost:8080` in the default browser.
6. Keep running (hold the window open) so the server job stays alive. Display a message: "Oolio Migration Toolkit is running. Close this window to stop the server."
7. On window close, stop the background server job cleanly.

```powershell
# Launch.ps1 — illustrative structure only, Claude Code writes the real implementation

# 1. Elevation check
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 2. Set execution policy for this process
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# 3. Start server in background
$job = Start-Job -FilePath "$PSScriptRoot\server\server.ps1" -ArgumentList $PSScriptRoot

# 4. Poll until ready
$ready = $false
for ($i = 0; $i -lt 10; $i++) {
    Start-Sleep -Milliseconds 500
    try { $r = Invoke-WebRequest -Uri "http://localhost:8080/ping" -UseBasicParsing -TimeoutSec 1; $ready = $true; break } catch {}
}
if (-not $ready) { Write-Host "Server failed to start."; exit 1 }

# 5. Open browser
Start-Process "http://localhost:8080"

# 6. Hold open
Write-Host "Oolio Migration Toolkit is running. Close this window to stop."
Wait-Job $job

# 7. Cleanup on close
Stop-Job $job
Remove-Job $job
```

---

## 4. Server — server.ps1

A simple HTTP listener using `System.Net.HttpListener`. Listens on `http://localhost:8080/`.

### Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/ping` | Health check — returns 200 OK |
| GET | `/` | Serves `ui/index.html` |
| GET | `/app.js` | Serves `ui/app.js` |
| GET | `/style.css` | Serves `ui/style.css` |
| GET | `/progress` | Returns `progress.json` as JSON |
| POST | `/progress` | Saves updated `progress.json` (body is JSON) |
| GET | `/run?module=X&step=Y` | Executes step Y in module X, streams output as Server-Sent Events |
| GET | `/input?module=X&step=Y&value=Z` | Passes user-supplied input value for steps that require it |

### Streaming output

The `/run` endpoint must stream output line by line using Server-Sent Events (SSE). Content-Type is `text/event-stream`. Each line of PowerShell output is sent as:

```
data: <line of output>\n\n
```

A final event signals completion:

```
data: __DONE__\n\n
```

An error event signals failure:

```
data: __ERROR__: <error message>\n\n
```

The server calls the appropriate module script function and pipes stdout/stderr through the SSE stream in real time. Use `$process.StandardOutput.ReadLine()` in a loop rather than waiting for the whole script to complete.

### progress.json schema

```json
{
  "bepoz": {
    "read-registry": "complete",
    "stop-sql": "skipped",
    "zip-data": "complete",
    "kill-processes": "complete",
    "clear-startup": "pending",
    "check-run-key": "pending",
    "delete-registry": "pending",
    "uninstall": "pending"
  },
  "windows": { ... },
  "dependencies": { ... },
  "oolio": { ... },
  "meta": {
    "terminalName": "Oolio-POS1",
    "terminalType": "POS",
    "hasCDS": true,
    "deploymentMode": "chrome",
    "lastUpdated": "2026-05-10T08:45:00"
  }
}
```

Step status values: `pending`, `complete`, `skipped`, `running`, `error`

The `meta` object stores values the technician supplies during the session (terminal name, terminal type, deployment mode, CDS presence). These persist across sessions.

---

## 5. Module Scripts

Each module script (`bepoz.ps1`, `windows.ps1`, `dependencies.ps1`, `oolio.ps1`) contains one PowerShell function per step. The router calls the appropriate function by step ID and streams its output.

All scripts dot-source `shared.ps1` for helper functions.

### shared.ps1 — Helper Functions

```powershell
# Read a value from the Bepoz registry key
function Get-BepozRegValue($valueName) {
    try {
        return (Get-ItemProperty -Path "HKCU:\Software\Backoffice" -Name $valueName -ErrorAction Stop).$valueName
    } catch {
        return $null
    }
}

# Write a timestamped log line to stdout (picked up by SSE stream)
function Write-Log($message, $level = "INFO") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Output "[$ts][$level] $message"
}

# Write a separator line
function Write-Section($title) {
    Write-Output ""
    Write-Output "--- $title ---"
}
```

---

## 6. Module 1 — Bepoz Software (bepoz.ps1)

### Step execution rules

Steps 1-4 (read-registry, stop-sql, zip-data, kill-processes) can be chained in an auto-run sequence. The auto-run pauses after zip-data and prompts the technician to confirm the backup zip exists before continuing.

Steps 5-7 (clear-startup, check-run-key, delete-registry) run individually with manual confirmation.

Step 8 (uninstall) always requires an explicit separate button press with a warning dialog.

### Step definitions

**Step ID: `read-registry`**  
Risk: safe

```powershell
function Invoke-BepozReadRegistry {
    Write-Section "Reading Bepoz registry configuration"
    
    $sqlServer = Get-BepozRegValue "SQL_Server"
    $dataPath = Get-BepozRegValue "DataPath"
    $backupPath = Get-BepozRegValue "BackupPath"
    
    if ($sqlServer) { Write-Log "SQL_Server: $sqlServer" } 
    else { Write-Log "SQL_Server: NOT FOUND" "WARN" }
    
    if ($dataPath) { Write-Log "DataPath: $dataPath" }
    else { Write-Log "DataPath: NOT FOUND" "WARN" }
    
    if ($backupPath) { Write-Log "BackupPath: $backupPath" }
    else { Write-Log "BackupPath: NOT FOUND" "WARN" }
    
    if (-not $sqlServer -or -not $dataPath -or -not $backupPath) {
        Write-Log "One or more required registry values are missing. Confirm this is a Bepoz terminal and retry." "ERROR"
    } else {
        Write-Log "All registry values confirmed. Safe to proceed." "OK"
    }
}
```

**Step ID: `stop-sql`**  
Risk: warn — confirm SQL is local before running

```powershell
function Invoke-BepozStopSQL {
    Write-Section "Stopping SQL Server instance"
    
    $sqlServer = Get-BepozRegValue "SQL_Server"
    if (-not $sqlServer) { Write-Log "SQL_Server not found in registry. Skipping." "WARN"; return }
    
    $instanceName = $sqlServer.Split('\')[1]
    Write-Log "Instance name derived from registry: $instanceName"
    
    $serviceName = "MSSQL`$$instanceName"
    Write-Log "Checking service: $serviceName"
    
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service $serviceName not found on this terminal. SQL may be on a venue server. Skipping." "WARN"
        return
    }
    
    Write-Log "Current service status: $($svc.Status)"
    
    if ($svc.Status -eq 'Running') {
        Write-Log "Stopping service..."
        Stop-Service -Name $serviceName -Force -ErrorAction Stop
        Write-Log "Service stopped." "OK"
    } else {
        Write-Log "Service is already stopped."
    }
    
    Write-Log "Setting service startup to Disabled..."
    Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
    Write-Log "Service disabled." "OK"
}
```

**Step ID: `zip-data`**  
Risk: safe

```powershell
function Invoke-BepozZipData {
    Write-Section "Creating Bepoz data backup"
    
    $dataPath = Get-BepozRegValue "DataPath"
    $backupPath = Get-BepozRegValue "BackupPath"
    
    if (-not $dataPath) { Write-Log "DataPath not found in registry." "ERROR"; return }
    if (-not $backupPath) { Write-Log "BackupPath not found in registry." "ERROR"; return }
    
    if (-not (Test-Path $dataPath)) { Write-Log "Data folder not found at: $dataPath" "ERROR"; return }
    
    if (-not (Test-Path $backupPath)) {
        Write-Log "Backup folder does not exist. Creating: $backupPath"
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
    $zipPath = "$backupPath\Bepoz_Data_$timestamp.zip"
    
    Write-Log "Source: $dataPath"
    Write-Log "Destination: $zipPath"
    Write-Log "Compressing..."
    
    Compress-Archive -Path $dataPath -DestinationPath $zipPath -Force -ErrorAction Stop
    
    $size = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Log "Backup complete. File size: $size MB" "OK"
    Write-Log "Zip location: $zipPath" "OK"
    Write-Log "IMPORTANT: Verify this file exists and has a non-zero size before proceeding." "WARN"
}
```

**Step ID: `kill-processes`**  
Risk: safe

```powershell
function Invoke-BepozKillProcesses {
    Write-Section "Terminating Bepoz processes"
    
    $procs = Get-Process | Where-Object { $_.Name -ilike "*bepoz*" -or $_.Name -ilike "*backoffice*" }
    
    if ($procs.Count -eq 0) {
        Write-Log "No running Bepoz processes found."
    } else {
        foreach ($p in $procs) {
            Write-Log "Stopping process: $($p.Name) (PID $($p.Id))"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Write-Log "Stopped: $($p.Name)" "OK"
        }
    }
    Write-Log "Process cleanup complete." "OK"
}
```

**Step ID: `clear-startup`**  
Risk: warn

```powershell
function Invoke-BepozClearStartup {
    Write-Section "Clearing shell:startup folder"
    
    $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    Write-Log "Startup folder: $startupPath"
    
    $items = Get-ChildItem -Path $startupPath -ErrorAction SilentlyContinue
    if ($items.Count -eq 0) {
        Write-Log "Startup folder is already empty."
    } else {
        Write-Log "Found $($items.Count) item(s):"
        foreach ($item in $items) { Write-Log "  - $($item.Name)" }
        Remove-Item -Path "$startupPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "All startup items removed." "OK"
    }
}
```

**Step ID: `check-run-key`**  
Risk: warn

```powershell
function Invoke-BepozCheckRunKey {
    Write-Section "Checking HKCU Run key for Bepoz entries"
    
    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $entries = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue
    
    Write-Log "Current Run key entries:"
    $entries.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
        Write-Log "  $($_.Name) = $($_.Value)"
    }
    
    $bepozNames = @("Bepoz", "BackOffice", "BepozPOS", "BEStartup")
    $removed = 0
    foreach ($name in $bepozNames) {
        if ($entries.$name) {
            Remove-ItemProperty -Path $runPath -Name $name -Force -ErrorAction SilentlyContinue
            Write-Log "Removed Run key entry: $name" "OK"
            $removed++
        }
    }
    
    if ($removed -eq 0) { Write-Log "No Bepoz Run key entries found." }
    else { Write-Log "$removed Bepoz Run key entry/entries removed." "OK" }
    Write-Log "Review the entries listed above. Remove any remaining Bepoz-related entries manually if needed." "WARN"
}
```

**Step ID: `delete-registry`**  
Risk: danger

```powershell
function Invoke-BepozDeleteRegistry {
    Write-Section "Deleting Bepoz registry key"
    
    $keyPath = "HKCU:\Software\Backoffice"
    
    if (-not (Test-Path $keyPath)) {
        Write-Log "Registry key not found. Already deleted or not present." "WARN"
        return
    }
    
    Write-Log "Deleting: $keyPath and all subkeys..."
    Remove-Item -Path $keyPath -Recurse -Force -ErrorAction Stop
    Write-Log "Registry key deleted successfully." "OK"
    
    if (Test-Path $keyPath) {
        Write-Log "WARNING: Key still present after deletion attempt." "ERROR"
    } else {
        Write-Log "Confirmed: Key no longer exists." "OK"
    }
}
```

**Step ID: `uninstall`**  
Risk: danger — optional, separate confirmation required

```powershell
function Invoke-BepozUninstall {
    Write-Section "Uninstalling Bepoz programs"
    Write-Log "Searching for Bepoz in installed programs..."
    
    $products = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -ilike "*Bepoz*" }
    
    if ($products.Count -eq 0) {
        Write-Log "No Bepoz programs found in installed programs list."
        Write-Log "Note: Bepoz may have been installed without WMI registration. Check C:\Bepoz\ manually." "WARN"
        return
    }
    
    foreach ($p in $products) {
        Write-Log "Found: $($p.Name) version $($p.Version)"
        Write-Log "Uninstalling $($p.Name)..."
        $result = $p.Uninstall()
        if ($result.ReturnValue -eq 0) {
            Write-Log "Uninstall complete: $($p.Name)" "OK"
        } else {
            Write-Log "Uninstall returned code $($result.ReturnValue) for $($p.Name)" "ERROR"
        }
    }
}
```

---

## 7. Module 2 — Windows Settings (windows.ps1)

### Step execution rules

Steps run individually. No auto-chain in this module — each step has meaningful decision points. The device rename step requires text input from the technician before it can execute. The IP switch step is conditional — skip silently if already DHCP.

### Step definitions

**Step ID: `verify-autologon`**  
Risk: safe

```powershell
function Invoke-WindowsVerifyAutologon {
    Write-Section "Verifying autologon configuration"
    
    $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $autoAdmin = (Get-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
    $defaultUser = (Get-ItemProperty -Path $winlogonPath -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
    $defaultDomain = (Get-ItemProperty -Path $winlogonPath -Name DefaultDomainName -ErrorAction SilentlyContinue).DefaultDomainName
    
    Write-Log "AutoAdminLogon: $autoAdmin"
    Write-Log "DefaultUserName: $defaultUser"
    Write-Log "DefaultDomainName: $defaultDomain"
    
    if ($autoAdmin -eq "1") {
        Write-Log "Autologon is active. Terminal will boot directly to user: $defaultUser" "OK"
    } else {
        Write-Log "Autologon is NOT active. Terminal will show login screen on reboot." "ERROR"
        Write-Log "Autologon must be restored before the final restart. Set AutoAdminLogon=1 in the Winlogon registry key." "WARN"
    }
}
```

**Step ID: `enable-firewall`**  
Risk: warn

```powershell
function Invoke-WindowsEnableFirewall {
    Write-Section "Enabling Windows Firewall"
    
    $profiles = @("Domain", "Private", "Public")
    foreach ($profile in $profiles) {
        Set-NetFirewallProfile -Profile $profile -Enabled True -ErrorAction SilentlyContinue
        $status = (Get-NetFirewallProfile -Profile $profile).Enabled
        Write-Log "Profile $profile firewall enabled: $status" $(if ($status) { "OK" } else { "ERROR" })
    }
}
```

**Step ID: `check-ip`**  
Risk: safe

```powershell
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
        Write-Log "  DHCP: $dhcp" $(if ($dhcp -eq "Enabled") { "OK" } else { "WARN" })
    }
}
```

**Step ID: `switch-dhcp`**  
Risk: warn — skips silently if already DHCP

```powershell
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
```

**Step ID: `rename-device`**  
Risk: warn — requires text input from UI  
Input parameter: `terminalName` (the suffix after "Oolio-", e.g. "POS1")

```powershell
function Invoke-WindowsRenameDevice {
    param([string]$terminalName)
    
    Write-Section "Renaming device"
    
    if (-not $terminalName -or $terminalName.Trim() -eq "") {
        Write-Log "No terminal name provided. Cannot rename." "ERROR"
        return
    }
    
    # Sanitise input — alphanumeric and hyphens only, max 12 chars for the suffix
    $clean = $terminalName.Trim() -replace '[^a-zA-Z0-9\-]', '' 
    if ($clean.Length -gt 12) { $clean = $clean.Substring(0, 12) }
    
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
```

**Step ID: `clean-desktop`**  
Risk: warn

```powershell
function Invoke-WindowsCleanDesktop {
    Write-Section "Cleaning desktop"
    
    $paths = @(
        "$env:USERPROFILE\Desktop",
        "C:\Users\Public\Desktop"
    )
    
    foreach ($path in $paths) {
        if (Test-Path $path) {
            $items = Get-ChildItem -Path $path
            Write-Log "Found $($items.Count) item(s) in $path"
            foreach ($item in $items) { Write-Log "  Removing: $($item.Name)" }
            Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared: $path" "OK"
        }
    }
    Write-Log "Desktop cleanup complete." "OK"
}
```

**Step ID: `set-wallpaper`**  
Risk: safe

```powershell
function Invoke-WindowsSetWallpaper {
    param([string]$toolkitRoot)
    
    Write-Section "Applying Oolio wallpaper"
    
    $assetPath = Join-Path $toolkitRoot "assets\wallpaper.jpg"
    $destFolder = "C:\Oolio\Assets"
    $destPath = "$destFolder\wallpaper.jpg"
    
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
    
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $destPath
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name WallpaperStyle -Value "10"
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name TileWallpaper -Value "0"
    
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
```

---

## 8. Module 3 — Oolio Dependencies (dependencies.ps1)

### Step execution rules

Steps 1 and 2 (Chrome, WebView2) can auto-chain. Steps 3 and 4 run individually.

### Step definitions

**Step ID: `check-chrome`**  
Risk: safe

```powershell
function Invoke-DepsCheckChrome {
    Write-Section "Checking Google Chrome"
    
    $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
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
```

**Step ID: `check-webview2`**  
Risk: safe

```powershell
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
```

**Step ID: `printer-utilities`**  
Risk: safe — links only, no auto-execution

This step opens the relevant download pages in the browser. No PowerShell execution required. The UI renders the links list and a "Mark done" button only.

Printer utility download links:
- Epson TM Utility: `https://download.epson-biz.com/modules/pos/`
- Epson Firmware Updater: `https://download.epson-biz.com/modules/pos/`
- Star Utility (TSP / mC-Print): `https://www.starmicronics.com/support/allproducts`
- Star Firmware Updater: `https://www.starmicronics.com/support/allproducts`
- Bixolon Utility and Firmware: `https://www.bixolon.com/sub_support_down.php`
- Element / Gravity Utility and Firmware: pending — update when Oolio confirms hosting location

**Step ID: `install-certs`**  
Risk: warn — Epson only

```powershell
function Invoke-DepsInstallCerts {
    param([string]$toolkitRoot)
    
    Write-Section "Installing Epson TLS certificates"
    
    $certsFolder = Join-Path $toolkitRoot "certs"
    
    if (-not (Test-Path $certsFolder)) {
        Write-Log "Certs folder not found at: $certsFolder" "ERROR"
        return
    }
    
    $certs = Get-ChildItem -Path $certsFolder -Filter "*.cer"
    
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
            Write-Log "Failed to install: $($cert.Name) — $result" "ERROR"
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
```

---

## 9. Module 4 — Oolio POS Setup (oolio.ps1)

### Step execution rules

The first step is a configuration step — the technician selects terminal type (POS or KDS) and deployment mode (Chrome or Windows app) and whether a CDS is present. These selections are stored in `progress.json` under `meta`. Subsequent steps in this module are shown or hidden based on those selections.

Steps 2, 3, 4, and 5 (folder creation, shortcut creation) can auto-chain. Steps 6 and 7 (startup config, final restart) require individual confirmation.

### Terminal type logic

| Terminal type | Deployment | CDS | Steps shown |
|---------------|------------|-----|-------------|
| POS | Chrome | Yes | create-folders, install-pos-chrome, install-cds-chrome, set-startup, final-restart |
| POS | Chrome | No | create-folders, install-pos-chrome, set-startup, final-restart |
| POS | Windows app | Yes | create-folders, install-pos-app, install-cds-app, set-startup, final-restart |
| POS | Windows app | No | create-folders, install-pos-app, set-startup, final-restart |
| KDS | Chrome (only) | N/A | create-folders, install-kds-chrome, set-startup, final-restart |

### Step definitions

**Step ID: `create-folders`**  
Risk: safe

```powershell
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
```

**Step ID: `install-pos-chrome`**  
Risk: safe — Chrome mode only

```powershell
function Invoke-OolioInstallPOSChrome {
    Write-Section "Creating Oolio POS Chrome kiosk shortcut"
    
    $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) {
        $chromePath = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    }
    if (-not (Test-Path $chromePath)) {
        Write-Log "Chrome not found. Install Chrome in the dependencies module first." "ERROR"
        return
    }
    
    $shortcutPath = "C:\Users\Public\Desktop\Oolio POS.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $chromePath
    $shortcut.Arguments = "--kiosk https://pos.oolio.io --no-first-run --disable-infobars"
    $shortcut.WindowStyle = 3
    $shortcut.Save()
    
    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches pos.oolio.io in fullscreen kiosk mode."
}
```

**Step ID: `install-cds-chrome`**  
Risk: safe — only shown if CDS is present

```powershell
function Invoke-OolioInstallCDSChrome {
    Write-Section "Creating Oolio CDS Chrome kiosk shortcut"
    
    $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) {
        $chromePath = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    }
    
    $shortcutPath = "C:\Users\Public\Desktop\Oolio CDS.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $chromePath
    # --window-position=1920,0 places it on the second display assuming 1920px primary
    # Technician should verify primary display resolution and adjust if needed
    $shortcut.Arguments = "--kiosk https://cds.oolio.io --no-first-run --disable-infobars --window-position=1920,0"
    $shortcut.WindowStyle = 3
    $shortcut.Save()
    
    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches cds.oolio.io fullscreen on second display (assumes 1920px primary)." "WARN"
    Write-Log "If primary display is not 1920px wide, update the --window-position X value in the shortcut manually."
}
```

**Step ID: `install-kds-chrome`**  
Risk: safe — KDS terminals only

```powershell
function Invoke-OolioInstallKDSChrome {
    Write-Section "Creating Oolio KDS Chrome kiosk shortcut"
    
    $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) {
        $chromePath = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    }
    
    $shortcutPath = "C:\Users\Public\Desktop\Oolio KDS.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $chromePath
    $shortcut.Arguments = "--kiosk https://kds.oolio.io --no-first-run --disable-infobars"
    $shortcut.WindowStyle = 3
    $shortcut.Save()
    
    Write-Log "Shortcut created: $shortcutPath" "OK"
    Write-Log "Launches kds.oolio.io fullscreen."
}
```

**Step ID: `set-startup`**  
Risk: warn  
Uses `terminalType` from `progress.json` meta to determine which entry to add.

```powershell
function Invoke-OolioSetStartup {
    param([string]$terminalType)
    
    Write-Section "Configuring startup"
    
    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    
    # Remove any previous Oolio entries first
    Remove-ItemProperty -Path $runPath -Name "OolioPOS" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runPath -Name "OolioKDS" -ErrorAction SilentlyContinue
    
    if ($terminalType -eq "KDS") {
        $shortcutPath = "C:\Users\Public\Desktop\Oolio KDS.lnk"
        $entryName = "OolioKDS"
    } else {
        $shortcutPath = "C:\Users\Public\Desktop\Oolio POS.lnk"
        $entryName = "OolioPOS"
    }
    
    if (-not (Test-Path $shortcutPath)) {
        Write-Log "Shortcut not found at: $shortcutPath" "ERROR"
        Write-Log "Create the application shortcut first, then run this step." "WARN"
        return
    }
    
    Set-ItemProperty -Path $runPath -Name $entryName -Value $shortcutPath
    Write-Log "Added $entryName to HKCU Run key." "OK"
    Write-Log "Oolio will launch automatically when the terminal boots and the user logs in."
    
    Write-Log "Verifying Run key..."
    $verify = (Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue).$entryName
    if ($verify) {
        Write-Log "Confirmed: $entryName = $verify" "OK"
    } else {
        Write-Log "Could not verify Run key entry." "ERROR"
    }
}
```

**Step ID: `final-restart`**  
Risk: warn — explicit confirmation required, 30-second countdown with cancel

```powershell
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
```

---

## 10. Front-End Specification (ui/)

### index.html

Single-page shell. Loads `style.css` and `app.js`. Contains one `<div id="app">` root element. No other content.

### app.js — Application logic

#### State model

```javascript
let state = {
  view: 'home',            // 'home' | 'module'
  activeModule: null,      // module id string
  progress: {},            // loaded from /progress on init, matches progress.json schema
  expandedSteps: {},       // { 'moduleId.stepId': true }
  runningStep: null,       // 'moduleId.stepId' currently executing
  outputLog: {},           // { 'moduleId.stepId': ['line1', 'line2', ...] }
  inputValues: {}          // { 'moduleId.stepId.fieldName': value } for steps requiring input
};
```

#### On load

1. Fetch `/progress` and populate `state.progress`
2. Render home view

#### Home view

Shows four module cards with:
- Module icon, name, description
- Progress bar showing steps complete / total
- "Complete" badge if all steps done
- Click to navigate to module view

Shows overall progress bar at top across all modules combined.

#### Module view

Shows back button, module header with progress, then all steps in order.

Steps that are hidden based on terminal type / deployment mode (from `progress.json` meta) are not rendered at all — not greyed out, not shown.

The first step in the Oolio module (`terminal-type`) is a special configuration step that renders a form with three questions before any scripts run:
- Terminal type: POS or KDS (radio)
- Deployment mode: Chrome or Windows app (radio) — hidden if KDS selected
- CDS present: Yes or No (radio) — hidden if KDS selected

On save, these values are written to `progress.json` meta via POST `/progress` and the module re-renders with the correct step set.

#### Step component

Each step renders:
1. Step header (number/tick, title, risk indicator) — always visible, click to expand
2. Step body (shown when expanded):
   - Note text
   - Links list (if step has links)
   - Input field (if step requires input — e.g. rename-device needs terminal name)
   - Run button (if step has a script) — triggers SSE execution
   - Output log area (shown during and after execution — monospace, dark background, scrollable, auto-scrolls to bottom)
   - Mark done / Skip buttons

#### Risk indicator colours

- safe: green dot
- warn: amber dot
- danger: red dot

Danger steps show an additional confirmation checkbox that must be ticked before the Run button becomes active. Checkbox label: "I confirm this action is intentional and the data backup is complete."

#### Auto-run chains

Module 1 (Bepoz) has a "Run safe steps" button at the top of the module that chains:
`read-registry` → `stop-sql` → `zip-data` → pause (show prompt: "Confirm the backup zip exists in the backup folder before continuing") → `kill-processes` → `clear-startup`

After those complete, remaining steps run individually.

Module 3 (Dependencies) has a "Check dependencies" button that chains:
`check-chrome` → `check-webview2`

#### SSE output handling

```javascript
function runStep(moduleId, stepId, inputValue) {
  state.runningStep = moduleId + '.' + stepId;
  state.outputLog[moduleId + '.' + stepId] = [];
  render();

  const url = `/run?module=${moduleId}&step=${stepId}${inputValue ? '&value=' + encodeURIComponent(inputValue) : ''}`;
  const es = new EventSource(url);

  es.onmessage = function(e) {
    if (e.data === '__DONE__') {
      es.close();
      state.runningStep = null;
      // Auto-mark as complete if no ERROR lines in output
      const log = state.outputLog[moduleId + '.' + stepId] || [];
      const hasError = log.some(line => line.includes('[ERROR]'));
      if (!hasError) {
        state.progress[moduleId] = state.progress[moduleId] || {};
        state.progress[moduleId][stepId] = 'complete';
        saveProgress();
      }
      render();
      return;
    }
    if (e.data.startsWith('__ERROR__:')) {
      state.outputLog[moduleId + '.' + stepId].push(e.data);
      es.close();
      state.runningStep = null;
      render();
      return;
    }
    state.outputLog[moduleId + '.' + stepId].push(e.data);
    render();
    // Auto-scroll output
    const el = document.getElementById('output-' + moduleId + '-' + stepId);
    if (el) el.scrollTop = el.scrollHeight;
  };

  es.onerror = function() {
    es.close();
    state.runningStep = null;
    render();
  };
}
```

#### Saving progress

```javascript
function saveProgress() {
  fetch('/progress', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(state.progress)
  });
}
```

---

## 11. Style Guide (style.css)

### Colour palette

```css
:root {
  --oolio-purple: #6239B1;
  --oolio-purple-light: #EAE4F8;
  --bg: #F5F5F5;
  --surface: #FFFFFF;
  --border: #E0E0E0;
  --text-primary: #1A1A1A;
  --text-secondary: #666666;
  --text-muted: #999999;
  --safe: #4CAF50;
  --safe-bg: #E8F5E9;
  --warn: #FF9800;
  --warn-bg: #FFF3E0;
  --danger: #F44336;
  --danger-bg: #FFEBEE;
  --ok-text: #2E7D32;
  --warn-text: #E65100;
  --error-text: #C62828;
  --output-bg: #1E1E1E;
  --output-text: #D4D4D4;
  --output-ok: #4EC9B0;
  --output-warn: #CE9178;
  --output-error: #F44747;
}
```

### Output log line colouring

Lines containing `[OK]` render in `--output-ok`.  
Lines containing `[WARN]` render in `--output-warn`.  
Lines containing `[ERROR]` render in `--output-error`.  
All other lines render in `--output-text`.

### Typography

System font stack: `-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif`  
Monospace (output log): `'Consolas', 'Courier New', monospace`

---

## 12. Key Business Rules Summary

These must be preserved in implementation:

1. **Registry-first.** Never hardcode Bepoz paths. Always read `DataPath`, `BackupPath`, and `SQL_Server` from `HKCU\Software\Backoffice` before acting.

2. **SQL instance name derivation.** Split `SQL_Server` value on `\` and take the right-hand part. The left part is the machine hostname (variable per site). The right part is the SQL instance name (also variable per site).

3. **SQL may not be local.** The `stop-sql` step must check whether the service exists on this terminal before attempting to stop it. If not found, log a warning and skip — do not error.

4. **Autologon must survive.** The Bepoz registry cleanup deletes `HKCU\Software\Backoffice` only. It must never touch `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`. The verify-autologon step confirms this is intact after cleanup.

5. **Desktop is safe to wipe.** This is a POS terminal. Remove everything from user and public desktop. The Oolio shortcut is placed by the setup module.

6. **Shell:startup is safe to wipe.** Same reasoning — POS terminal only.

7. **Device rename prefix is hardcoded as `Oolio-`.** The technician supplies only the suffix. Input is sanitised to alphanumeric and hyphens, max 12 characters.

8. **Restart is held to the end.** No individual steps trigger a restart mid-process.

9. **Danger steps require a confirmation tick.** The UI must enforce this — the Run button is disabled until the checkbox is ticked.

10. **Progress persists across sessions.** A technician may complete modules 1 and 2 on one visit and modules 3 and 4 on another. `progress.json` saves state after every step completion.

11. **Terminal type drives module 4 step visibility.** KDS terminals never see CDS steps. Chrome-mode terminals never see Windows app installer steps. This is driven by `progress.json` meta values set in the configuration step.

12. **sc.exe not sc.** In PowerShell, `sc` is an alias for `Set-Content`. Always use `sc.exe` explicitly, or better use `Stop-Service` and `Set-Service` PowerShell cmdlets directly.

13. **Certificates loop.** The cert install step processes every `.cer` file in the `certs\` folder. File naming convention is the printer IP address (e.g. `192.168.1.50.cer`). Epson only.

14. **CDS window position assumption.** The CDS Chrome shortcut uses `--window-position=1920,0` assuming a 1920px wide primary display. The output log must warn the technician to verify and adjust if the primary display differs.

---

## 13. Out of Scope for v1

The following are known future items, not to be built in v1:

- Windows app mode installer (.exe) for Oolio POS and CDS — installer location to be confirmed when SharePoint hosting moves
- Element/Gravity printer utility download link — pending Oolio confirmation of hosting location
- Screensaver configuration — wallpaper only for v1
- Multi-terminal batch mode — one terminal at a time for v1
- Remote execution via ScreenConnect — local only for v1
- Automatic printer IP detection — technician assigns IPs via printer utility manually

---

*Specification prepared by Stephen, Head of Onboarding NSW. For Claude Code development use only.*
