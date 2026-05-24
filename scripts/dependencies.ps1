# dependencies.ps1 - Module 3: Oolio Dependencies step functions

function Invoke-DepsCheckChrome {
    Write-Section "Checking Google Chrome"

    $chromePath    = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    $chromePathx86 = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"

    if (Test-Path $chromePath) {
        $ver = (Get-Item $chromePath).VersionInfo.FileVersion
        Write-Log "Chrome found at: $chromePath" "OK"
        Write-Log "Version: $ver"
        return
    }
    if (Test-Path $chromePathx86) {
        $ver = (Get-Item $chromePathx86).VersionInfo.FileVersion
        Write-Log "Chrome found at: $chromePathx86" "OK"
        Write-Log "Version: $ver"
        return
    }

    Write-Log "Chrome not found. Downloading enterprise installer..." "WARN"

    $msiUrl  = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
    $msiPath = Join-Path $env:TEMP "googlechromestandaloneenterprise64.msi"

    Write-Log "Source: $msiUrl"
    if (-not (Invoke-DownloadWithHeartbeat -Url $msiUrl -OutFile $msiPath -ProgressLabel "Downloading Google Chrome")) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    if (-not (Test-InstallerSignature -Path $msiPath -ExpectedSubjectLike "*Google LLC*")) {
        Write-Log "Refusing to run unverified installer. The downloaded MSI may be corrupt or tampered with." "ERROR"
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log "Installing silently (msiexec /i /qn /norestart)..."
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "`"$msiPath`"", "/qn", "/norestart") -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing Chrome (msiexec)"
    # WaitForExit() ensures ExitCode is flushed — Start-Process can return null
    # if ExitCode is read before the process handle is fully released.
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    Write-Log "msiexec exit code: $exitCode"

    # Give Windows Installer a moment to finish writing files after msiexec exits.
    Start-Sleep -Seconds 3

    # msiexec success codes: 0 = success, 3010 = success (restart required),
    # 1641 = success (restart initiated), 1638 = newer version already present.
    $msiSuccessCodes = @(0, 3010, 1641, 1638)
    $chromeFound = (Test-Path $chromePath) -or (Test-Path $chromePathx86)

    if ($chromeFound) {
        $verPath = if (Test-Path $chromePath) { $chromePath } else { $chromePathx86 }
        $ver = (Get-Item $verPath).VersionInfo.FileVersion
        Write-Log "Chrome installed and verified: $verPath version $ver" "OK"
        if ($exitCode -notin $msiSuccessCodes) {
            Write-Log "Note: msiexec exit code was $exitCode (non-standard but Chrome is present)." "WARN"
        }
    } else {
        Write-Log "msiexec exit code $exitCode - Chrome was not found on disk." "ERROR"
        Write-Log "Common causes: 1618 = another installer running; 1619 = MSI could not be opened; 1603 = fatal error." "WARN"
    }

    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
}

function Invoke-DepsInstallTeamViewer {
    Write-Section "Installing TeamViewer (full version)"

    $tvPaths = @(
        "C:\Program Files\TeamViewer\TeamViewer.exe",
        "C:\Program Files (x86)\TeamViewer\TeamViewer.exe"
    )
    foreach ($p in $tvPaths) {
        if (Test-Path $p) {
            $ver = (Get-Item $p).VersionInfo.FileVersion
            Write-Log "TeamViewer already installed at: $p" "OK"
            Write-Log "Version: $ver"
            return
        }
    }

    Write-Log "TeamViewer not found. Downloading installer..." "WARN"

    $url       = "https://download.teamviewer.com/download/TeamViewer_Setup_x64.exe"
    $installer = Join-Path $env:TEMP "TeamViewer_Setup_x64.exe"

    Write-Log "Source: $url"
    if (-not (Invoke-DownloadWithHeartbeat -Url $url -OutFile $installer -ProgressLabel "Downloading TeamViewer")) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    if (-not (Test-InstallerSignature -Path $installer -ExpectedSubjectLike "*TeamViewer*")) {
        Write-Log "Refusing to run unverified installer. The downloaded EXE may be corrupt or tampered with." "ERROR"
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log "Installing silently (/S)..."
    $proc = Start-Process -FilePath $installer -ArgumentList "/S" -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing TeamViewer"

    # Give the TeamViewer background service installer a moment to finish writing
    # files after the outer process exits.
    Start-Sleep -Seconds 5

    $tvFound = $false
    foreach ($p in $tvPaths) {
        if (Test-Path $p) {
            $ver = (Get-Item $p).VersionInfo.FileVersion
            Write-Log "TeamViewer installed and verified: $p version $ver" "OK"
            $tvFound = $true
            break
        }
    }

    if (-not $tvFound) {
        if ($proc.ExitCode -eq 0) {
            Write-Log "Installer exited cleanly but TeamViewer.exe was not found. It may still be installing - check Program Files in a moment." "WARN"
        } else {
            Write-Log "TeamViewer installer exited with code $($proc.ExitCode) and TeamViewer.exe was not found on disk." "ERROR"
        }
    } elseif ($proc.ExitCode -ne 0) {
        Write-Log "Note: installer exit code was $($proc.ExitCode) (non-standard but TeamViewer is present)." "WARN"
    }

    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}

function Invoke-DepsCheckEpsonNetConfig {
    Write-Section "Checking EpsonNet Config"

    $knownPaths = @(
        "C:\Program Files (x86)\EPSON\EpsonNetConfig\ENConfig.exe",
        "C:\Program Files\EPSON\EpsonNetConfig\ENConfig.exe"
    )
    foreach ($p in $knownPaths) {
        if (Test-Path $p) {
            $ver = (Get-Item $p).VersionInfo.FileVersion
            Write-Log "EpsonNet Config found at: $p" "OK"
            Write-Log "Version: $ver"
            return
        }
    }

    $regInstalled = @(
        Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'EpsonNet Config' }
        Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'EpsonNet Config' }
    )
    if ($regInstalled.Count -gt 0) {
        Write-Log "EpsonNet Config is installed: $($regInstalled[0].DisplayName) $($regInstalled[0].DisplayVersion)" "OK"
        return
    }

    Write-Log "EpsonNet Config not found. Downloading installer..." "WARN"

    $url       = "https://ftp.epson.com/drivers/ENCU_4.9.11.exe"
    $installer = Join-Path $env:TEMP "ENCU_4.9.11.exe"

    Write-Log "Source: $url"
    if (-not (Invoke-DownloadWithHeartbeat -Url $url -OutFile $installer -ProgressLabel "Downloading EpsonNet Config")) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    if (-not (Test-InstallerSignature -Path $installer -ExpectedSubjectLike "*EPSON*")) {
        Write-Log "Refusing to run unverified installer. The downloaded EXE may be corrupt or tampered with." "ERROR"
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class EpsonDialogHelper {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWndParent, EnumChildProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    public const uint BM_CLICK = 0x00F5;
    public const int SW_RESTORE = 9;

    public static List<IntPtr> FindWindowsWithTitle(string titleFragment) {
        var result = new List<IntPtr>();
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            if (sb.ToString().IndexOf(titleFragment, StringComparison.OrdinalIgnoreCase) >= 0)
                result.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // Find the first child Button whose text contains buttonTextFragment (case-insensitive).
    public static IntPtr FindButtonContaining(IntPtr parent, string buttonTextFragment) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, (hWnd, lParam) => {
            var cls = new StringBuilder(64);
            GetClassName(hWnd, cls, 64);
            if (cls.ToString() == "Button") {
                var txt = new StringBuilder(256);
                GetWindowText(hWnd, txt, 256);
                if (txt.ToString().IndexOf(buttonTextFragment, StringComparison.OrdinalIgnoreCase) >= 0) {
                    found = hWnd;
                    return false;
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@ -ErrorAction SilentlyContinue

    # Click a button inside the first matching window. Returns $true if clicked.
    function Invoke-AutoClick {
        param([string]$WinTitle, [string]$BtnText, [int]$TimeoutSecs = 60, [string]$Label)
        $deadline = (Get-Date).AddSeconds($TimeoutSecs)
        while ((Get-Date) -lt $deadline) {
            foreach ($hwnd in [EpsonDialogHelper]::FindWindowsWithTitle($WinTitle)) {
                $btn = [EpsonDialogHelper]::FindButtonContaining($hwnd, $BtnText)
                if ($btn -ne [IntPtr]::Zero) {
                    [EpsonDialogHelper]::ShowWindow($hwnd, [EpsonDialogHelper]::SW_RESTORE) | Out-Null
                    [EpsonDialogHelper]::SetForegroundWindow($hwnd) | Out-Null
                    Start-Sleep -Milliseconds 300
                    [EpsonDialogHelper]::SendMessage($btn, [EpsonDialogHelper]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                    Write-Log $Label "OK"
                    return $true
                }
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Log "Timed out waiting for: $Label" "WARN"
        return $false
    }

    Write-Log "Starting installer..."
    $proc = Start-Process -FilePath $installer -ArgumentList "/SILENT" -PassThru

    # Stage 0: initial "Epson Installer" info dialog — click OK.
    # This is the first thing ENCU_4.9.11.exe shows before the WinZip SFX runs.
    Invoke-AutoClick -WinTitle "Epson Installer" -BtnText "OK" -TimeoutSecs 60 `
        -Label "Epson Installer info dialog: clicked OK"

    # Stage 1: WinZip Self-Extractor — click Setup.
    # Appears after the info dialog is dismissed; extracts and launches InstallShield.
    Invoke-AutoClick -WinTitle "EpsonNetConfig" -BtnText "Setup" -TimeoutSecs 60 `
        -Label "WinZip SFX: clicked Setup"

    # Stage 2: InstallShield language selection — click "Next"
    # Title: "EpsonNet Config V4 - InstallShield Wizard"
    Invoke-AutoClick -WinTitle "EpsonNet Config" -BtnText "Next" -TimeoutSecs 60 `
        -Label "InstallShield language dialog: clicked Next"

    # Stage 3: Any remaining InstallShield wizard pages (feature select, licence, ready, finish).
    # Keep clicking Next / Install / Finish until no more EpsonNet Config wizard windows appear.
    $wizardDeadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $wizardDeadline) {
        $wins = [EpsonDialogHelper]::FindWindowsWithTitle("EpsonNet Config")
        if ($wins.Count -eq 0) { break }
        $clicked = $false
        foreach ($hwnd in $wins) {
            foreach ($btn in @("Finish", "Install", "Next")) {
                $b = [EpsonDialogHelper]::FindButtonContaining($hwnd, $btn)
                if ($b -ne [IntPtr]::Zero) {
                    [EpsonDialogHelper]::ShowWindow($hwnd, [EpsonDialogHelper]::SW_RESTORE) | Out-Null
                    [EpsonDialogHelper]::SetForegroundWindow($hwnd) | Out-Null
                    Start-Sleep -Milliseconds 300
                    [EpsonDialogHelper]::SendMessage($b, [EpsonDialogHelper]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                    Write-Log "InstallShield wizard: clicked $btn" "OK"
                    $clicked = $true
                    Start-Sleep -Milliseconds 800
                    break
                }
            }
            if ($clicked) { break }
        }
        if (-not $clicked) { Start-Sleep -Milliseconds 500 }
    }

    # Wait for all Epson setup processes to exit.
    Write-Log "Waiting for Epson setup to complete..."
    $installDeadline = (Get-Date).AddSeconds(120)
    $start = Get-Date
    while ((Get-Date) -lt $installDeadline) {
        $epsonProcs = @(Get-Process | Where-Object { $_.Path -and $_.Path -match 'epson|ENCU' })
        if ($epsonProcs.Count -eq 0) { break }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($elapsed % 10 -lt 1) { Write-Log "Epson setup still running, elapsed ${elapsed}s" }
        Start-Sleep -Seconds 1
    }
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    Write-Log "Epson setup complete after ${elapsed}s." "OK"

    if ($proc.ExitCode -eq 0) {
        Write-Log "EpsonNet Config installer exited cleanly." "OK"
        $found = $false
        foreach ($p in $knownPaths) {
            if (Test-Path $p) {
                $ver = (Get-Item $p).VersionInfo.FileVersion
                Write-Log "Verified: $p version $ver" "OK"
                $found = $true
                break
            }
        }
        if (-not $found) {
            $check = @(
                Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -match 'EpsonNet Config' }
            )
            if ($check.Count -gt 0) {
                Write-Log "Verified via registry: $($check[0].DisplayName) $($check[0].DisplayVersion)" "OK"
                $found = $true
            }
        }
        if (-not $found) {
            Write-Log "Installer reported success but EpsonNet Config was not found at known paths. Check Program Files manually." "WARN"
        }

        # Remove desktop shortcuts left by the Epson installer.
        $desktopPaths = @(
            "C:\Users\Public\Desktop",
            "$env:USERPROFILE\Desktop"
        )
        foreach ($dir in $desktopPaths) {
            Get-ChildItem -Path $dir -Filter "*EpsonNet*" -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "Removed desktop shortcut: $($_.Name)" "OK"
            }
        }
    } else {
        Write-Log "EpsonNet Config installer exited with code $($proc.ExitCode)." "ERROR"
    }

    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}

function Invoke-DepsCheckWebView2 {
    Write-Section "Checking Edge WebView2"

    $regPath   = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    $installed = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue

    if ($installed) {
        Write-Log "Edge WebView2 is installed." "OK"
        Write-Log "Version: $($installed.pv)"
        return
    }

    Write-Log "Edge WebView2 not found. Downloading Evergreen Bootstrapper..." "WARN"

    $url       = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
    $installer = Join-Path $env:TEMP "MicrosoftEdgeWebview2Setup.exe"

    Write-Log "Source: $url"
    if (-not (Invoke-DownloadWithHeartbeat -Url $url -OutFile $installer -ProgressLabel "Downloading Edge WebView2")) {
        Write-Log "The terminal needs internet at this point. Re-run when connectivity is available." "WARN"
        return
    }

    if (-not (Test-InstallerSignature -Path $installer -ExpectedSubjectLike "*Microsoft Corporation*")) {
        Write-Log "Refusing to run unverified installer. The downloaded EXE may be corrupt or tampered with." "ERROR"
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log "Installing silently (/silent /install)..."
    $proc = Start-Process -FilePath $installer -ArgumentList @("/silent", "/install") -PassThru -NoNewWindow
    Wait-ProcessWithHeartbeat -Process $proc -Label "Installing WebView2"

    if ($proc.ExitCode -eq 0) {
        $installed = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($installed) {
            Write-Log "Edge WebView2 installed successfully." "OK"
            Write-Log "Version: $($installed.pv)"
        } else {
            Write-Log "Installer reported success but the EdgeUpdate Clients registry key is still missing." "WARN"
            Write-Log "WebView2 may need a reboot to register, or the bootstrapper failed silently. Check Programs and Features." "WARN"
        }
    } else {
        Write-Log "WebView2 installer exited with code $($proc.ExitCode)." "ERROR"
    }

    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
}

