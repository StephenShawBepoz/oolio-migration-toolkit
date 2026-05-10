# bepoz.ps1 - Module 1: Bepoz Software removal step functions

function Invoke-BepozReadRegistry {
    Write-Section "Reading Bepoz registry configuration"

    $keyPath = "HKCU:\Software\Backoffice"

    if (-not (Test-Path $keyPath)) {
        Write-Log "Registry key $keyPath not found." "WARN"
        Write-Log "This terminal may not have Bepoz installed, or it has already been removed." "WARN"
        Write-Log "Skipping registry read. Steps that need a specific value will report individually when they run." "WARN"
        return
    }

    $sqlServer  = Get-BepozRegValue "SQL_Server"
    $dataPath   = Get-BepozRegValue "DataPath"
    $backupPath = Get-BepozRegValue "BackupPath"

    if ($sqlServer)  { Write-Log "SQL_Server: $sqlServer" "OK" }
    else             { Write-Log "SQL_Server: not present (expected on tills - SQL usually lives on a venue server)" "WARN" }

    if ($dataPath)   { Write-Log "DataPath: $dataPath" "OK" }
    else             { Write-Log "DataPath: not present" "WARN" }

    if ($backupPath) { Write-Log "BackupPath: $backupPath" "OK" }
    else             { Write-Log "BackupPath: not present" "WARN" }

    if ($sqlServer -and $dataPath -and $backupPath) {
        Write-Log "All registry values confirmed. Safe to proceed." "OK"
    } else {
        Write-Log "Some values missing. Downstream steps that need them will report when they run; this step is informational only." "WARN"
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

    # Missing registry values are not errors here - just nothing to back up. The
    # read-registry step already warned about them; downstream steps that need a
    # value still report individually.
    if (-not $dataPath) {
        Write-Log "DataPath not present in registry. Nothing to back up - skipping." "WARN"
        return
    }
    if (-not $backupPath) {
        Write-Log "BackupPath not present in registry. Cannot determine backup destination - skipping." "WARN"
        return
    }

    if (-not (Test-Path $dataPath)) {
        Write-Log "Data folder not found at: $dataPath" "WARN"
        Write-Log "Nothing to back up - skipping." "WARN"
        return
    }

    # Count source files. An empty Data\ folder is a legitimate state on a fresh
    # till or after a prior partial cleanup. Treat as a no-op success rather than
    # an error so the migrate flow continues.
    $sourceFiles = @(Get-ChildItem -Path $dataPath -Recurse -File -ErrorAction SilentlyContinue)
    Write-Log "Source: $dataPath ($($sourceFiles.Count) file(s))"
    if ($sourceFiles.Count -eq 0) {
        Write-Log "Data folder is empty. Nothing to back up - treating as success." "WARN"
        return
    }

    if (-not (Test-Path $backupPath)) {
        Write-Log "Backup folder does not exist. Creating: $backupPath"
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
    $zipPath   = Join-Path $backupPath "Bepoz_Data_$timestamp.zip"

    Write-Log "Destination: $zipPath"
    Write-Log "Compressing (using .NET ZipFile - no 2 GB limit)..."

    # PowerShell 5.1's Compress-Archive buffers through MemoryStream and chokes on archives
    # larger than ~2 GB ("Stream was too long"). Use the underlying .NET API directly.
    if (Test-Path $zipPath) { Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $dataPath,
            $zipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false   # do not include the source folder name in the archive root
        )
    } catch {
        Write-Log "Compression failed: $($_.Exception.Message)" "ERROR"
        if (Test-Path $zipPath) { Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue }
        return
    }

    if (-not (Test-Path $zipPath)) {
        Write-Log "Zip file was not created at $zipPath." "ERROR"
        return
    }

    # An empty ZipFile produced by CreateFromDirectory is ~22 bytes. If the source
    # had files but the archive came out essentially empty, that is a real failure.
    $sizeBytes = (Get-Item $zipPath).Length
    $sizeMB    = [math]::Round($sizeBytes / 1MB, 2)
    if ($sizeBytes -lt 100) {
        Write-Log "Zip is $sizeBytes bytes (essentially empty) but source had $($sourceFiles.Count) file(s). Treating as failure." "ERROR"
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log "Backup complete. File size: $sizeMB MB ($sizeBytes bytes), $($sourceFiles.Count) source file(s)." "OK"
    Write-Log "Zip location: $zipPath" "OK"
    Write-Log "IMPORTANT: Verify this file exists and has a non-zero size before proceeding." "WARN"
}

function Invoke-BepozTerminateProcesses {
    Write-Section "Terminating processes running from C:\Bepoz"

    $bepozRoot = "C:\Bepoz"
    if (-not (Test-Path $bepozRoot)) {
        Write-Log "Bepoz root folder not found: $bepozRoot. Nothing to terminate."
        return
    }

    $rootPrefix = (Resolve-Path $bepozRoot).Path.TrimEnd('\') + '\'
    Write-Log "Scanning for processes whose executable lives under $rootPrefix"

    $hits = @()
    foreach ($proc in Get-Process) {
        $path = $null
        try { $path = $proc.Path } catch { $path = $null }
        if ($path -and $path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $hits += [pscustomobject]@{ Proc = $proc; Path = $path }
        }
    }

    if ($hits.Count -eq 0) {
        Write-Log "No running processes found under $bepozRoot."
        Write-Log "Process cleanup complete." "OK"
        return
    }

    Write-Log "Found $($hits.Count) matching process(es):"
    foreach ($h in $hits) {
        Write-Log "  PID $($h.Proc.Id) - $($h.Proc.Name) - $($h.Path)"
    }

    foreach ($h in $hits) {
        Write-Log "Stopping: $($h.Proc.Name) (PID $($h.Proc.Id))"
        Stop-Process -Id $h.Proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 200
        if (Get-Process -Id $h.Proc.Id -ErrorAction SilentlyContinue) {
            Write-Log "Failed to stop: $($h.Proc.Name) (PID $($h.Proc.Id))" "ERROR"
        } else {
            Write-Log "Stopped: $($h.Proc.Name)" "OK"
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

    # Export the Run key directly to C:\OolioBackup so it survives the C:\Bepoz cleanup
    # in the consolidate-backups step.
    $backupRoot = "C:\OolioBackup"
    if (-not (Test-Path $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        Write-Log "Created consolidated backup folder: $backupRoot"
    }

    $timestamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
    $exportFile = Join-Path $backupRoot "HKCU_Run_$timestamp.reg"

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

function Invoke-BepozConsolidateBackups {
    # Move every .zip from C:\Bepoz\Backup\ (and subdirectories) into C:\OolioBackup\,
    # then remove C:\Bepoz\ entirely. The .reg from check-run-key already lives in
    # C:\OolioBackup\ so we don't need to relocate it.
    Write-Section "Consolidating backups and removing Bepoz folder"

    $bepozRoot   = "C:\Bepoz"
    $bepozBackup = Join-Path $bepozRoot "Backup"
    $oolioBackup = "C:\OolioBackup"

    if (-not (Test-Path $oolioBackup)) {
        New-Item -ItemType Directory -Path $oolioBackup -Force | Out-Null
        Write-Log "Created: $oolioBackup" "OK"
    }

    # Find every .zip recursively under C:\Bepoz\Backup\
    $sourceZips = @()
    if (Test-Path $bepozBackup) {
        $sourceZips = @(Get-ChildItem -Path $bepozBackup -Filter "*.zip" -File -Recurse -ErrorAction SilentlyContinue)
    } else {
        Write-Log "$bepozBackup does not exist. Nothing to move from there." "WARN"
    }

    if ($sourceZips.Count -gt 0) {
        Write-Log "Moving $($sourceZips.Count) zip file(s) from $bepozBackup to $oolioBackup..."
        foreach ($z in $sourceZips) {
            $dest = Join-Path $oolioBackup $z.Name
            # If the destination already has a same-named zip, preserve both with a suffix.
            if (Test-Path $dest) {
                $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $dest = Join-Path $oolioBackup ("{0}_{1}{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($z.Name), $stamp, $z.Extension)
            }
            $sizeMB = [math]::Round($z.Length / 1MB, 2)
            Move-Item -Path $z.FullName -Destination $dest -Force
            Write-Log "  Moved: $($z.Name) ($sizeMB MB) -> $dest" "OK"
        }
    } else {
        Write-Log "No .zip files found under $bepozBackup."
    }

    # Verify all moved files are present in the destination.
    $destZips = @(Get-ChildItem -Path $oolioBackup -Filter "*.zip" -File -ErrorAction SilentlyContinue)
    Write-Log "Destination now contains $($destZips.Count) zip file(s):"
    foreach ($d in $destZips) {
        $sz = [math]::Round($d.Length / 1MB, 2)
        Write-Log "  $($d.Name) - $sz MB"
    }

    # Safety guard: confirm at least one Bepoz_Data_*.zip is present before deletion.
    $dataBackups = @($destZips | Where-Object { $_.Name -like "Bepoz_Data_*.zip" })
    if ($dataBackups.Count -eq 0) {
        Write-Log "No Bepoz_Data_*.zip found in $oolioBackup. ABORTING to protect data." "ERROR"
        Write-Log "Run the zip-data step first if applicable, then retry." "WARN"
        return
    }
    Write-Log "Confirmed $($dataBackups.Count) data backup zip(s) in $oolioBackup." "OK"

    # Now remove C:\Bepoz\ entirely.
    if (Test-Path $bepozRoot) {
        Write-Log "Removing $bepozRoot and all its contents..."
        Remove-Item -Path $bepozRoot -Recurse -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        if (Test-Path $bepozRoot) {
            Write-Log "$bepozRoot still exists after removal attempt. Some files may be locked - close any tools using them and retry." "ERROR"
        } else {
            Write-Log "$bepozRoot removed successfully." "OK"
        }
    } else {
        Write-Log "$bepozRoot does not exist. Nothing to remove." "WARN"
    }

    Write-Log "Final state: $oolioBackup retained with $($destZips.Count) zip(s); $bepozRoot removed." "OK"
}
