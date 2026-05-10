# shared.ps1 - helper functions dot-sourced by every module script

# Read a value from the Bepoz registry key (HKCU:\Software\Backoffice)
function Get-BepozRegValue {
    param([string]$valueName)
    try {
        return (Get-ItemProperty -Path "HKCU:\Software\Backoffice" -Name $valueName -ErrorAction Stop).$valueName
    } catch {
        return $null
    }
}

# Write a timestamped log line. Picked up by the SSE stream.
function Write-Log {
    param([string]$message, [string]$level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Output "[$ts][$level] $message"
}

# Write a section header.
function Write-Section {
    param([string]$title)
    Write-Output ""
    Write-Output "--- $title ---"
}
