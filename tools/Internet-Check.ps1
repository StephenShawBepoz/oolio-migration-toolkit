# Internet-Check.ps1
# Standalone connectivity monitor for a Windows POS terminal.
#
# Usage:
#   Right-click -> Run with PowerShell
#   (or from a PowerShell window: .\Internet-Check.ps1)
#
# Logs CSV + human-readable .log to the same folder as the script. Probes every
# 10 seconds by default. Press Ctrl+C to stop - a summary is printed and saved.
#
# What it captures per probe:
#   - Active default-route interface (so you can prove if 4G ever took over)
#   - Wi-Fi SSID / BSSID / signal % / TX rate
#   - Default gateway ping (separates "Wi-Fi dropped" from "internet dropped")
#   - DNS resolution against system resolver and 1.1.1.1
#   - ICMP to 1.1.1.1 and 8.8.8.8
#   - HTTPS GET to cloudflare.com (some networks block ICMP - HTTPS is the real test)
#   - Verdict: Online / WifiOnlyNoInternet / DnsFailure / Offline

param(
    [int]$IntervalSeconds = 10,
    [string]$OutputFolder = $PSScriptRoot
)

if (-not $OutputFolder) { $OutputFolder = Get-Location }
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

$stamp     = Get-Date -Format "yyyy-MM-dd_HHmmss"
$computer  = $env:COMPUTERNAME
$csvPath   = Join-Path $OutputFolder "internet-check-$computer-$stamp.csv"
$logPath   = Join-Path $OutputFolder "internet-check-$computer-$stamp.log"

# ---- Helpers ----------------------------------------------------------------

function Write-LogLine {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    $colour = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Gray" }
    }
    Write-Host $line -ForegroundColor $colour
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

function Get-ActiveInterface {
    # Default route winner = the interface currently carrying internet traffic.
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
                 Sort-Object -Property RouteMetric, InterfaceMetric |
                 Select-Object -First 1
        if (-not $route) { return $null }
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Name        = $adapter.Name
            Type        = $adapter.MediaType        # "Native 802.11" / "802.3" / "Wireless WAN"
            Description = $adapter.InterfaceDescription
            Gateway     = $route.NextHop
            Status      = $adapter.Status
            LinkSpeed   = $adapter.LinkSpeed
        }
    } catch {
        return $null
    }
}

function Get-WifiInfo {
    # netsh output is locale-sensitive; we match on the canonical English keys.
    # If the terminal is set to a non-English locale this may need tweaking.
    $info = [pscustomobject]@{
        SSID = ""; BSSID = ""; SignalPct = $null; TxRate = ""; RxRate = ""; State = ""
    }
    try {
        $out = netsh wlan show interfaces 2>&1 | Out-String
        if ($out -match 'State\s*:\s*(.+)')                  { $info.State     = $matches[1].Trim() }
        if ($out -match '^\s*SSID\s*:\s*(.+)$')               { $info.SSID      = $matches[1].Trim() }
        if ($out -match 'BSSID\s*:\s*([0-9a-f:]+)')           { $info.BSSID     = $matches[1].Trim() }
        if ($out -match 'Signal\s*:\s*(\d+)\s*%')             { $info.SignalPct = [int]$matches[1] }
        if ($out -match 'Transmit rate \(Mbps\)\s*:\s*(.+)')  { $info.TxRate    = $matches[1].Trim() }
        if ($out -match 'Receive rate \(Mbps\)\s*:\s*(.+)')   { $info.RxRate    = $matches[1].Trim() }
    } catch {}
    return $info
}

function Test-PingTarget {
    param([string]$Target, [int]$Count = 3)
    try {
        $results = Test-Connection -ComputerName $Target -Count $Count -ErrorAction Stop
        $ok = @($results | Where-Object { $_.StatusCode -eq 0 -or $_.ResponseTime -ne $null })
        if ($ok.Count -eq 0) {
            return [pscustomobject]@{ Ok = $false; AvgMs = $null; LossPct = 100 }
        }
        $avg = [math]::Round(($ok | Measure-Object -Property ResponseTime -Average).Average, 1)
        $loss = [int](100 - (($ok.Count / $Count) * 100))
        return [pscustomobject]@{ Ok = $true; AvgMs = $avg; LossPct = $loss }
    } catch {
        return [pscustomobject]@{ Ok = $false; AvgMs = $null; LossPct = 100 }
    }
}

function Test-DnsResolve {
    param([string]$Name, [string]$Server)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $params = @{ Name = $Name; Type = "A"; QuickTimeout = $true; ErrorAction = "Stop" }
        if ($Server) { $params["Server"] = $Server }
        $null = Resolve-DnsName @params
        $sw.Stop()
        return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Ok = $false; Ms = $null }
    }
}

function Test-HttpsTarget {
    param([string]$Url)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -Method Head -ErrorAction Stop
        $sw.Stop()
        return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds; Status = [int]$resp.StatusCode }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Ok = $false; Ms = $null; Status = $null }
    }
}

# ---- Header ----------------------------------------------------------------

@(
    "=" * 78
    "Internet connectivity monitor"
    "Computer:   $computer"
    "Started:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "Interval:   $IntervalSeconds seconds"
    "CSV log:    $csvPath"
    "Text log:   $logPath"
    "Press Ctrl+C to stop and print summary."
    "=" * 78
) | ForEach-Object {
    Write-Host $_ -ForegroundColor Cyan
    Add-Content -Path $logPath -Value $_ -Encoding UTF8
}

# CSV header
$csvHeader = "Timestamp,Verdict,Interface,InterfaceType,LinkSpeed,Gateway,WifiSSID,WifiBSSID,WifiSignalPct,WifiTxRate,GatewayPingMs,GatewayLossPct,DnsSystemOk,DnsSystemMs,DnsCloudflareOk,DnsCloudflareMs,PingCloudflareMs,PingCloudflareLoss,PingGoogleMs,PingGoogleLoss,HttpsOk,HttpsMs,HttpsStatus"
Set-Content -Path $csvPath -Value $csvHeader -Encoding UTF8

# ---- Stats counters --------------------------------------------------------

$stats = @{
    TotalProbes               = 0
    OnlineProbes              = 0
    OfflineProbes             = 0
    WifiOnlyNoInternetProbes  = 0
    DnsFailureProbes          = 0
    InterfaceFlips            = 0
    LastInterface             = $null
    OutageStartedAt           = $null
    LongestOutageSec          = 0
    CurrentOutageSec          = 0
    Start                     = Get-Date
    LastHourSummaryAt         = Get-Date
}

function Csv-Escape {
    param($v)
    if ($null -eq $v) { return "" }
    $s = "$v"
    if ($s -match '[,"\r\n]') { return '"' + ($s -replace '"', '""') + '"' }
    return $s
}

function Write-Summary {
    param([switch]$Final)
    $elapsed = [int]((Get-Date) - $stats.Start).TotalSeconds
    $uptimePct = if ($stats.TotalProbes -gt 0) {
        [math]::Round(($stats.OnlineProbes / $stats.TotalProbes) * 100, 2)
    } else { 0 }

    $title = if ($Final) { "FINAL SUMMARY" } else { "Hourly summary" }
    $lines = @(
        ""
        "------ $title ------"
        "Elapsed (s):              $elapsed"
        "Total probes:             $($stats.TotalProbes)"
        "Online probes:            $($stats.OnlineProbes)  (${uptimePct}% uptime)"
        "Offline probes:           $($stats.OfflineProbes)"
        "Wi-Fi but no internet:    $($stats.WifiOnlyNoInternetProbes)  <-- key signal"
        "DNS-only failures:        $($stats.DnsFailureProbes)"
        "Interface switches:       $($stats.InterfaceFlips)"
        "Longest outage (sec):     $($stats.LongestOutageSec)"
        "----------------------"
        ""
    )
    foreach ($l in $lines) {
        Write-Host $l -ForegroundColor Cyan
        Add-Content -Path $logPath -Value $l -Encoding UTF8
    }
}

# ---- Main loop -------------------------------------------------------------

try {
    while ($true) {
        $now = Get-Date

        $iface = Get-ActiveInterface
        $wifi  = Get-WifiInfo

        $gwPing  = if ($iface -and $iface.Gateway) { Test-PingTarget -Target $iface.Gateway -Count 2 } else { $null }
        $dnsSys  = Test-DnsResolve -Name "cloudflare.com"
        $dnsCf   = Test-DnsResolve -Name "cloudflare.com" -Server "1.1.1.1"
        $pingCf  = Test-PingTarget -Target "1.1.1.1" -Count 3
        $pingGo  = Test-PingTarget -Target "8.8.8.8" -Count 3
        $https   = Test-HttpsTarget -Url "https://www.cloudflare.com"

        # Verdict logic
        $hasGateway   = $gwPing -and $gwPing.Ok
        $hasIcmp      = ($pingCf.Ok -or $pingGo.Ok)
        $hasHttps     = $https.Ok
        $hasDns       = ($dnsSys.Ok -or $dnsCf.Ok)
        $hasInternet  = ($hasIcmp -or $hasHttps)

        $verdict = "Online"
        $level   = "OK"
        if (-not $hasInternet -and -not $hasGateway) {
            $verdict = "Offline"; $level = "ERROR"
        } elseif (-not $hasInternet -and $hasGateway) {
            $verdict = "WifiOnlyNoInternet"; $level = "ERROR"
        } elseif (-not $hasDns -and $hasIcmp) {
            $verdict = "DnsFailure"; $level = "WARN"
        } elseif (-not $hasHttps -and $hasIcmp) {
            $verdict = "HttpBlockedOrSlow"; $level = "WARN"
        }

        # Track interface flips
        $ifaceName = if ($iface) { $iface.Name } else { "(none)" }
        if ($stats.LastInterface -and $stats.LastInterface -ne $ifaceName) {
            $stats.InterfaceFlips++
            Write-LogLine "Interface switched: $($stats.LastInterface) -> $ifaceName" "WARN"
        }
        $stats.LastInterface = $ifaceName

        # Track outage durations
        if ($verdict -eq "Online") {
            if ($stats.OutageStartedAt) {
                $outageSec = [int]((Get-Date) - $stats.OutageStartedAt).TotalSeconds
                Write-LogLine "Outage ended after ${outageSec}s" "OK"
                if ($outageSec -gt $stats.LongestOutageSec) { $stats.LongestOutageSec = $outageSec }
                $stats.OutageStartedAt = $null
            }
        } else {
            if (-not $stats.OutageStartedAt) {
                $stats.OutageStartedAt = $now
                Write-LogLine "Outage started ($verdict)" "WARN"
            }
        }

        $stats.TotalProbes++
        switch ($verdict) {
            "Online"             { $stats.OnlineProbes++ }
            "Offline"            { $stats.OfflineProbes++ }
            "WifiOnlyNoInternet" { $stats.WifiOnlyNoInternetProbes++ }
            "DnsFailure"         { $stats.DnsFailureProbes++ }
        }

        # Console summary line
        $sigStr = if ($wifi.SignalPct -ne $null) { "$($wifi.SignalPct)%" } else { "-" }
        $gwMs   = if ($gwPing -and $gwPing.Ok) { "$($gwPing.AvgMs)ms" } else { "FAIL" }
        $cfMs   = if ($pingCf.Ok) { "$($pingCf.AvgMs)ms" } else { "FAIL" }
        $httpStr = if ($https.Ok) { "$($https.Ms)ms" } else { "FAIL" }
        $msg = "$verdict | iface=$ifaceName | SSID=$($wifi.SSID) sig=$sigStr | gw=$gwMs | 1.1.1.1=$cfMs | https=$httpStr"
        Write-LogLine $msg $level

        # CSV row
        $row = @(
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
            $verdict,
            $ifaceName,
            $(if ($iface) { $iface.Type } else { "" }),
            $(if ($iface) { $iface.LinkSpeed } else { "" }),
            $(if ($iface) { $iface.Gateway } else { "" }),
            $wifi.SSID,
            $wifi.BSSID,
            $wifi.SignalPct,
            $wifi.TxRate,
            $(if ($gwPing) { $gwPing.AvgMs } else { "" }),
            $(if ($gwPing) { $gwPing.LossPct } else { "" }),
            $dnsSys.Ok,
            $dnsSys.Ms,
            $dnsCf.Ok,
            $dnsCf.Ms,
            $pingCf.AvgMs,
            $pingCf.LossPct,
            $pingGo.AvgMs,
            $pingGo.LossPct,
            $https.Ok,
            $https.Ms,
            $https.Status
        ) | ForEach-Object { Csv-Escape $_ }
        Add-Content -Path $csvPath -Value ($row -join ",") -Encoding UTF8

        # Hourly summary
        if (((Get-Date) - $stats.LastHourSummaryAt).TotalMinutes -ge 60) {
            Write-Summary
            $stats.LastHourSummaryAt = Get-Date
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    Write-Summary -Final
    Write-Host "CSV saved: $csvPath" -ForegroundColor Cyan
    Write-Host "Log saved: $logPath" -ForegroundColor Cyan
}
