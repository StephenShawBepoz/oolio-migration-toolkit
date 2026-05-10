# bepoz.ps1 - Module 1: Bepoz Software removal step functions

function Invoke-BepozReadRegistry {
    Write-Section "Reading Bepoz registry configuration"

    $sqlServer  = Get-BepozRegValue "SQL_Server"
    $dataPath   = Get-BepozRegValue "DataPath"
    $backupPath = Get-BepozRegValue "BackupPath"

    if ($sqlServer)  { Write-Log "SQL_Server: $sqlServer" }  else { Write-Log "SQL_Server: NOT FOUND" "WARN" }
    if ($dataPath)   { Write-Log "DataPath: $dataPath" }      else { Write-Log "DataPath: NOT FOUND" "WARN" }
    if ($backupPath) { Write-Log "BackupPath: $backupPath" }  else { Write-Log "BackupPath: NOT FOUND" "WARN" }

    if (-not $sqlServer -or -not $dataPath -or -not $backupPath) {
        Write-Log "One or more required registry values are missing. Confirm this is a Bepoz terminal and retry." "ERROR"
    } else {
        Write-Log "All registry values confirmed. Safe to proceed." "OK"
    }
}

function Invoke-BepozStopSQL {
    Write-Section "Stopping SQL Server instance"

    $sqlServer = Get-BepozRegValue "SQL_Server"
    if (-not $sqlServer) { Write-Log "SQL_Server not found in registry. Skipping." "WARN"; return }

    $parts = $sqlServer.Split('\')
    if ($parts.Length -lt 2) {
        Write-Log "SQL_Server value '$sqlServer' is not in HOST\INSTANCE format. Skipping." "WARN"
        return
    }
    $instanceName = $parts[1]
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

function Invoke-BepozZipData {
    Write-Section "Creating Bepoz data backup"

    $dataPath   = Get-BepozRegValue "DataPath"
    $backupPath = Get-BepozRegValue "BackupPath"

    if (-not $dataPath)   { Write-Log "DataPath not found in registry." "ERROR"; return }
    if (-not $backupPath) { Write-Log "BackupPath not found in registry." "ERROR"; return }

    if (-not (Test-Path $dataPath)) {
        Write-Log "Data folder not found at: $dataPath" "ERROR"
        return
    }

    if (-not (Test-Path $backupPath)) {
        Write-Log "Backup folder does not exist. Creating: $backupPath"
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
    $zipPath = Join-Path $backupPath "Bepoz_Data_$timestamp.zip"

    Write-Log "Source: $dataPath"
    Write-Log "Destination: $zipPath"
    Write-Log "Compressing..."

    Compress-Archive -Path $dataPath -DestinationPath $zipPath -Force -ErrorAction Stop

    $size = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Log "Backup complete. File size: $size MB" "OK"
    Write-Log "Zip location: $zipPath" "OK"
    Write-Log "IMPORTANT: Verify this file exists and has a non-zero size before proceeding." "WARN"
}

function Invoke-BepozKillProcesses {
    Write-Section "Terminating Bepoz processes"

    $procs = Get-Process | Where-Object { $_.Name -ilike "*bepoz*" -or $_.Name -ilike "*backoffice*" }

    if (-not $procs -or $procs.Count -eq 0) {
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

function Invoke-BepozClearStartup {
    Write-Section "Clearing shell:startup folder"

    $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    Write-Log "Startup folder: $startupPath"

    $items = @(Get-ChildItem -Path $startupPath -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) {
        Write-Log "Startup folder is already empty."
    } else {
        Write-Log "Found $($items.Count) item(s):"
        foreach ($item in $items) { Write-Log "  - $($item.Name)" }
        Remove-Item -Path "$startupPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "All startup items removed." "OK"
    }
}

function Invoke-BepozCheckRunKey {
    Write-Section "Exporting and cleaning HKCU Run key"

    $runPath    = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runPathReg = "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"

    # Export the Run key to the same directory as the data backup, before any changes.
    $backupPath = Get-BepozRegValue "BackupPath"
    if (-not $backupPath) {
        Write-Log "BackupPath not found in HKCU\Software\Backoffice. Cannot export Run key." "ERROR"
        Write-Log "Run the read-registry step first to confirm the registry is intact." "WARN"
        return
    }

    if (-not (Test-Path $backupPath)) {
        Write-Log "Backup folder does not exist. Creating: $backupPath"
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
    $exportFile = Join-Path $backupPath "HKCU_Run_$timestamp.reg"

    Write-Log "Exporting HKCU Run key to: $exportFile"
    reg export $runPathReg $exportFile /y | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exportFile)) {
        Write-Log "Failed to export Run key (reg.exe exit code $LASTEXITCODE). Aborting before any cleanup." "ERROR"
        return
    }

    $size = [math]::Round((Get-Item $exportFile).Length / 1KB, 2)
    Write-Log "Export complete. File size: $size KB" "OK"
    Write-Log "Restore later with: reg import `"$exportFile`""

    # Now list current entries and remove known Bepoz ones.
    $entries = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue

    Write-Log "Current Run key entries:"
    if ($entries) {
        $entries.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
            Write-Log "  $($_.Name) = $($_.Value)"
        }
    }

    $bepozNames = @("Bepoz", "BackOffice", "BepozPOS", "BEStartup")
    $removed = 0
    foreach ($name in $bepozNames) {
        if ($entries -and $entries.$name) {
            Remove-ItemProperty -Path $runPath -Name $name -Force -ErrorAction SilentlyContinue
            Write-Log "Removed Run key entry: $name" "OK"
            $removed++
        }
    }

    if ($removed -eq 0) { Write-Log "No Bepoz Run key entries found." }
    else { Write-Log "$removed Bepoz Run key entry/entries removed." "OK" }
    Write-Log "Review the entries listed above. Remove any remaining Bepoz-related entries manually if needed." "WARN"
}

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

function Invoke-BepozUninstall {
    Write-Section "Uninstalling Bepoz programs"
    Write-Log "Searching for Bepoz in installed programs..."

    $products = @(Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -ilike "*Bepoz*" })

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
