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
#   - ICMP burst (N pings) to 1.1.1.1 with loss% + single ping to 8.8.8.8
#   - HTTPS HEAD to cloudflare.com (generic internet path)
#   - HTTPS HEAD to the Oolio app endpoint (the connection the venue depends on)
#   - Verdict: Online / WifiOnlyNoInternet / DnsFailure / HttpBlockedOrSlow /
#              AppEndpointFailure / Offline
#
# Periodic summary every $SummaryEveryMin minutes (default 15) writes p50/p95/p99
# latency rollups for ICMP / generic HTTPS / app HTTPS so brownouts are visible
# even when uptime is 100%. The .log file rotates at $LogRotateMB (default 100).
#
# Robustness:
#   - Probes run in parallel via .NET async tasks so a slow probe can't blow
#     the cycle budget.
#   - On every transition into a non-Online verdict, a tracert runs async in
#     the background and its output is appended to the log when it completes.
#   - WLAN AutoConfig + DHCP event logs are polled every 60s so AP-side
#     deauth/roam events are recorded alongside the probe verdicts.
#   - Self-test at startup verifies writable outputs and that each probe
#     mechanism works before entering the long-running loop.

param(
    [int]$IntervalSeconds   = 10,
    [string]$OutputFolder   = $PSScriptRoot,
    [string]$VenueLabel     = "",
    # Second HTTPS probe - the application endpoint the venue actually depends on.
    # If cloudflare.com is fine but this fails repeatedly, the problem is the app
    # backend, not the link. Set to "" to disable.
    [string]$AppEndpoint    = "https://pos.oolio.io",
    # Per-cycle ICMP burst to the primary internet target. Captures partial loss
    # (e.g. 1/3 lost = 33% loss%) that single-shot pings cannot see.
    [int]$PingBurstCount    = 3,
    # Rotate the .log file when it exceeds this many MB. CSV is left untouched
    # (small) - only the human-readable text log grows.
    [int]$LogRotateMB       = 100,
    # Periodic summary cadence in minutes. Was 60; lowered so even a hard-killed
    # window has a recent rollup in the log.
    [int]$SummaryEveryMin   = 15
)

if (-not $OutputFolder) { $OutputFolder = Get-Location }
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

$stamp     = Get-Date -Format "yyyy-MM-dd_HHmmss"
$computer  = $env:COMPUTERNAME
$slug      = if ($VenueLabel) { ($VenueLabel -replace '[^A-Za-z0-9\-]', '_') + "-" } else { "" }
$csvPath   = Join-Path $OutputFolder "internet-check-$slug$computer-$stamp.csv"
$logPath   = Join-Path $OutputFolder "internet-check-$slug$computer-$stamp.log"

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

# ---- Parallel probes via .NET async tasks ----------------------------------
#
# Each cycle kicks off Ping + DNS + HTTPS in parallel. WaitAll caps the total
# cycle at $WaitMs so a single hung probe can't violate $IntervalSeconds.
# HttpClient is created once and reused (creating it per call leaks sockets).

Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$script:HttpClient = [System.Net.Http.HttpClient]::new()
$script:HttpClient.Timeout = [TimeSpan]::FromSeconds(5)

function Start-AsyncPing {
    param([string]$Target, [int]$TimeoutMs = 1500)
    $p = New-Object System.Net.NetworkInformation.Ping
    return @{ Ping = $p; Task = $p.SendPingAsync($Target, $TimeoutMs) }
}

function Read-PingResult {
    param($Handle)
    $t = $Handle.Task
    try {
        if (-not $t.IsCompleted) { return [pscustomobject]@{ Ok = $false; AvgMs = $null; LossPct = 100 } }
        if ($t.IsFaulted -or $t.IsCanceled) { return [pscustomobject]@{ Ok = $false; AvgMs = $null; LossPct = 100 } }
        $r = $t.Result
        if ($r.Status -eq 'Success') {
            return [pscustomobject]@{ Ok = $true; AvgMs = [int]$r.RoundtripTime; LossPct = 0 }
        }
        return [pscustomobject]@{ Ok = $false; AvgMs = $null; LossPct = 100 }
    } finally {
        try { $Handle.Ping.Dispose() } catch {}
    }
}

function Start-AsyncPingBurst {
    # Fire N pings in parallel to the same target so we can compute loss%.
    # Returns an array of handles; read with Read-PingBurstResult.
    param([string]$Target, [int]$Count = 3, [int]$TimeoutMs = 1500)
    $handles = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $handles += , (Start-AsyncPing -Target $Target -TimeoutMs $TimeoutMs)
    }
    return $handles
}

function Read-PingBurstResult {
    param($Handles)
    $sent = $Handles.Count
    $okMs = @()
    foreach ($h in $Handles) {
        $r = Read-PingResult -Handle $h
        if ($r.Ok) { $okMs += $r.AvgMs }
    }
    $recv = $okMs.Count
    $lossPct = if ($sent -gt 0) { [int]((($sent - $recv) / $sent) * 100) } else { 100 }
    $avg = if ($recv -gt 0) { [int](($okMs | Measure-Object -Average).Average) } else { $null }
    return [pscustomobject]@{
        Sent    = $sent
        Recv    = $recv
        LossPct = $lossPct
        AvgMs   = $avg
        Ok      = ($recv -gt 0)
    }
}

function Start-AsyncDns {
    param([string]$Name)
    return @{ Task = [System.Net.Dns]::GetHostAddressesAsync($Name); Started = [System.Diagnostics.Stopwatch]::StartNew() }
}

function Read-DnsResult {
    param($Handle)
    $sw = $Handle.Started; $sw.Stop()
    if ($Handle.Task.IsCompleted -and -not $Handle.Task.IsFaulted -and -not $Handle.Task.IsCanceled) {
        return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds }
    }
    return [pscustomobject]@{ Ok = $false; Ms = $null }
}

function Start-AsyncHttps {
    param([string]$Url)
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $Url)
    return @{
        Task    = $script:HttpClient.SendAsync($req)
        Started = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Read-HttpsResult {
    param($Handle)
    $sw = $Handle.Started; $sw.Stop()
    if ($Handle.Task.IsCompleted -and -not $Handle.Task.IsFaulted -and -not $Handle.Task.IsCanceled) {
        $resp = $Handle.Task.Result
        return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds; Status = [int]$resp.StatusCode }
    }
    return [pscustomobject]@{ Ok = $false; Ms = $null; Status = $null }
}

# DNS-against-a-specific-server isn't supported by .NET Dns. We still want to
# detect "system resolver broken but Cloudflare DNS works" - which is why this
# stays a separate sync probe via Resolve-DnsName. It runs in parallel with the
# async tasks by being kicked off after them and read after WaitAll returns.
function Test-DnsResolveSpecific {
    param([string]$Name, [string]$Server)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Resolve-DnsName -Name $Name -Server $Server -Type A -QuickTimeout -ErrorAction Stop
        $sw.Stop()
        return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Ok = $false; Ms = $null }
    }
}

# ---- Traceroute on outage transition ---------------------------------------
#
# Fired as a background Start-Process so the main loop doesn't block. The PID
# and a marker file are tracked so subsequent cycles can detect completion and
# splice the output back into the main log.

$script:PendingTraceroutes = [System.Collections.ArrayList]::new()

function Start-TracerouteOnOutage {
    param([string]$Target = "1.1.1.1", [string]$Reason = "")
    $traceFile = Join-Path $OutputFolder "traceroute-$(Get-Date -Format 'yyyyMMdd_HHmmss').tmp"
    try {
        $proc = Start-Process -FilePath "tracert.exe" `
                              -ArgumentList "-d","-h","15","-w","1000",$Target `
                              -RedirectStandardOutput $traceFile `
                              -NoNewWindow -PassThru -ErrorAction Stop
        $null = $script:PendingTraceroutes.Add([pscustomobject]@{
            Process  = $proc
            File     = $traceFile
            Target   = $Target
            Reason   = $Reason
            StartedAt = (Get-Date)
        })
        Write-LogLine "Traceroute to $Target started (reason: $Reason, PID $($proc.Id))" "WARN"
    } catch {
        Write-LogLine "Failed to launch tracert: $($_.Exception.Message)" "WARN"
    }
}

function Drain-CompletedTraceroutes {
    $stillRunning = [System.Collections.ArrayList]::new()
    foreach ($t in $script:PendingTraceroutes) {
        if ($t.Process.HasExited) {
            try {
                $output = Get-Content -Path $t.File -Raw -Encoding UTF8 -ErrorAction Stop
                Write-LogLine "---- TRACEROUTE to $($t.Target) (reason: $($t.Reason)) ----" "WARN"
                foreach ($ln in ($output -split "`r?`n")) {
                    if ($ln.Trim().Length -gt 0) { Add-Content -Path $logPath -Value "    $ln" -Encoding UTF8 }
                }
                Write-LogLine "---- end traceroute ----" "WARN"
            } catch {
                Write-LogLine "Could not read traceroute output: $($_.Exception.Message)" "WARN"
            } finally {
                Remove-Item -Path $t.File -Force -ErrorAction SilentlyContinue
            }
        } else {
            # Kill traceroutes that have been running too long (>60s)
            $age = ((Get-Date) - $t.StartedAt).TotalSeconds
            if ($age -gt 60) {
                try { $t.Process.Kill() } catch {}
                Write-LogLine "Traceroute to $($t.Target) killed after ${age}s (timeout)" "WARN"
                Remove-Item -Path $t.File -Force -ErrorAction SilentlyContinue
            } else {
                $null = $stillRunning.Add($t)
            }
        }
    }
    $script:PendingTraceroutes = $stillRunning
}

# ---- WLAN + DHCP event log polling -----------------------------------------
#
# Microsoft-Windows-WLAN-AutoConfig/Operational records connect / disconnect /
# roam events and *the reason code from the AP*. Microsoft-Windows-Dhcp-Client/
# Operational records lease renewals, NAKs, and ACKs. Cross-referencing these
# with probe verdicts is what tells the network person *why* Wi-Fi dropped,
# not just *that* it dropped.

$script:LastEventScan = (Get-Date).AddSeconds(-1)
# Common WLAN event IDs we care about (full list at https://learn.microsoft.com/en-us/windows/win32/nativewifi/wlan-msm-notification-source-codes)
$script:WlanInterestingIds = @(8001, 8002, 8003, 11000, 11001, 11002, 11004, 11005, 11006, 11010)
$script:DhcpInterestingIds = @(50036, 50037, 50038, 50066, 50067)

function Drain-NetworkEvents {
    $sinceTime = $script:LastEventScan
    $now = Get-Date
    $script:LastEventScan = $now

    foreach ($spec in @(
        @{ Log = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Ids = $script:WlanInterestingIds; Tag = "WLAN" }
        @{ Log = 'Microsoft-Windows-Dhcp-Client/Operational';      Ids = $script:DhcpInterestingIds; Tag = "DHCP" }
    )) {
        try {
            $filter = @{ LogName = $spec.Log; StartTime = $sinceTime }
            if ($spec.Ids -and $spec.Ids.Count -gt 0) { $filter["Id"] = $spec.Ids }
            $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop -MaxEvents 50
            foreach ($e in ($events | Sort-Object TimeCreated)) {
                $msg = ($e.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                Write-LogLine "[$($spec.Tag) evt $($e.Id)] $msg" "WARN"
            }
        } catch {
            # Log may not exist on this terminal or be disabled - swallow silently
            # after the first call, otherwise it spams the log every minute.
        }
    }
}

# ---- Self-test -------------------------------------------------------------

function Invoke-SelfTest {
    Write-LogLine "Running self-test..." "INFO"
    $problems = @()

    # 1. CSV writable
    try {
        Set-Content -Path $csvPath -Value "selftest" -Encoding UTF8 -ErrorAction Stop
        Remove-Item -Path $csvPath -Force -ErrorAction SilentlyContinue
    } catch {
        $problems += "Cannot write CSV at $csvPath - $($_.Exception.Message)"
    }

    # 2. tracert.exe exists
    $tracert = Get-Command tracert.exe -ErrorAction SilentlyContinue
    if (-not $tracert) {
        $problems += "tracert.exe not found - outage traceroutes will be skipped"
    } else {
        Write-LogLine "  tracert.exe: $($tracert.Source)" "OK"
    }

    # 3. .NET Ping works
    try {
        $h = Start-AsyncPing -Target "1.1.1.1" -TimeoutMs 2000
        $null = $h.Task.Wait(2500)
        $r = Read-PingResult -Handle $h
        if ($r.Ok) { Write-LogLine "  ICMP to 1.1.1.1: $($r.AvgMs)ms" "OK" }
        else       { $problems += "ICMP to 1.1.1.1 failed at startup - network unreachable already?" }
    } catch {
        $problems += ".NET Ping failed: $($_.Exception.Message)"
    }

    # 4. DNS works
    try {
        $h = Start-AsyncDns -Name "cloudflare.com"
        $null = $h.Task.Wait(3000)
        $r = Read-DnsResult -Handle $h
        if ($r.Ok) { Write-LogLine "  DNS resolve cloudflare.com: $($r.Ms)ms" "OK" }
        else       { $problems += "DNS resolution failed at startup - already broken?" }
    } catch {
        $problems += "DNS task failed: $($_.Exception.Message)"
    }

    # 5. HTTPS works
    try {
        $h = Start-AsyncHttps -Url "https://www.cloudflare.com"
        $null = $h.Task.Wait(6000)
        $r = Read-HttpsResult -Handle $h
        if ($r.Ok) { Write-LogLine "  HTTPS HEAD cloudflare.com: $($r.Ms)ms (HTTP $($r.Status))" "OK" }
        else       { $problems += "HTTPS to cloudflare.com failed at startup" }
    } catch {
        $problems += "HTTPS task failed: $($_.Exception.Message)"
    }

    # 6. Wi-Fi info (warn-only - terminal might be on Ethernet)
    $w = Get-WifiInfo
    if ($w.SSID) {
        Write-LogLine "  Wi-Fi: SSID='$($w.SSID)' BSSID=$($w.BSSID) signal=$($w.SignalPct)%" "OK"
    } else {
        Write-LogLine "  Wi-Fi: no SSID reported (terminal may be on Ethernet, or netsh locale is non-English)" "WARN"
    }

    # 7. Default-route interface
    $iface = Get-ActiveInterface
    if ($iface) {
        Write-LogLine "  Default route: $($iface.Name) ($($iface.Type)) via $($iface.Gateway)" "OK"
    } else {
        $problems += "No active default-route interface detected - no internet path exists"
    }

    if ($problems.Count -gt 0) {
        Write-LogLine "SELF-TEST FAILURES:" "ERROR"
        foreach ($p in $problems) { Write-LogLine "  - $p" "ERROR" }
        Write-LogLine "Continuing anyway (some probes may always fail)." "WARN"
        return $false
    }

    Write-LogLine "Self-test passed." "OK"
    return $true
}

# ---- Header ----------------------------------------------------------------

$venueDisplay = if ($VenueLabel) { $VenueLabel } else { "(unset - pass -VenueLabel to tag this run)" }
@(
    "=" * 78
    "Internet connectivity monitor"
    "Venue:      $venueDisplay"
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

$null = Invoke-SelfTest

# CSV header
$csvHeader = "Timestamp,Venue,Verdict,Interface,InterfaceType,LinkSpeed,Gateway,WifiSSID,WifiBSSID,WifiSignalPct,WifiTxRate,GatewayPingMs,DnsSystemOk,DnsSystemMs,DnsCloudflareOk,DnsCloudflareMs,PingCloudflareMs,PingCloudflareLossPct,PingGoogleMs,HttpsOk,HttpsMs,HttpsStatus,AppHttpsOk,AppHttpsMs,AppHttpsStatus,CycleMs"
Set-Content -Path $csvPath -Value $csvHeader -Encoding UTF8

# ---- Stats counters --------------------------------------------------------

$stats = @{
    TotalProbes               = 0
    OnlineProbes              = 0
    OfflineProbes             = 0
    WifiOnlyNoInternetProbes  = 0
    DnsFailureProbes          = 0
    HttpBlockedProbes         = 0
    AppEndpointFailureProbes  = 0
    AppEndpointFails          = 0   # consecutive failure run
    InterfaceFlips            = 0
    LastInterface             = $null
    LastVerdict               = "Online"
    OutageStartedAt           = $null
    LongestOutageSec          = 0
    Start                     = Get-Date
    LastHourSummaryAt         = Get-Date
    LastEventDrainAt          = Get-Date
    OverBudgetCycles          = 0
    TotalLossPct              = 0   # sum of per-cycle loss% (for averaging)
    LossCycles                = 0   # cycles with >0% loss
}

# Bounded ring buffers for percentile reporting. ~7200 entries = 10h at 5s interval.
# When full, oldest entry is overwritten - so percentiles always reflect a recent window.
$script:LatencyBufSize = 7200
$script:HttpsLatencies = New-Object System.Collections.ArrayList
$script:IcmpLatencies  = New-Object System.Collections.ArrayList
$script:AppLatencies   = New-Object System.Collections.ArrayList

function Add-Latency {
    param([System.Collections.ArrayList]$Buf, [int]$Value)
    if ($null -eq $Value) { return }
    if ($Buf.Count -ge $script:LatencyBufSize) { $Buf.RemoveAt(0) }
    $null = $Buf.Add($Value)
}

function Get-Percentile {
    param([System.Collections.ArrayList]$Buf, [double]$P)
    if ($Buf.Count -eq 0) { return $null }
    $sorted = ($Buf | Sort-Object)
    $idx = [int][math]::Floor(($P / 100.0) * ($sorted.Count - 1))
    return $sorted[$idx]
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

    $title = if ($Final) { "FINAL SUMMARY" } else { "Periodic summary" }
    $avgLoss = if ($stats.LossCycles -gt 0) { [math]::Round($stats.TotalLossPct / $stats.LossCycles, 1) } else { 0 }

    function _Fmt($v) { if ($null -eq $v) { "-" } else { "${v}ms" } }
    $icmpP50 = _Fmt (Get-Percentile -Buf $script:IcmpLatencies  -P 50)
    $icmpP95 = _Fmt (Get-Percentile -Buf $script:IcmpLatencies  -P 95)
    $icmpP99 = _Fmt (Get-Percentile -Buf $script:IcmpLatencies  -P 99)
    $httpP50 = _Fmt (Get-Percentile -Buf $script:HttpsLatencies -P 50)
    $httpP95 = _Fmt (Get-Percentile -Buf $script:HttpsLatencies -P 95)
    $httpP99 = _Fmt (Get-Percentile -Buf $script:HttpsLatencies -P 99)
    $appP50  = _Fmt (Get-Percentile -Buf $script:AppLatencies   -P 50)
    $appP95  = _Fmt (Get-Percentile -Buf $script:AppLatencies   -P 95)
    $appP99  = _Fmt (Get-Percentile -Buf $script:AppLatencies   -P 99)

    $lines = @(
        ""
        "------ $title ------"
        "Elapsed (s):              $elapsed"
        "Total probes:             $($stats.TotalProbes)"
        "Online probes:            $($stats.OnlineProbes)  (${uptimePct}% uptime)"
        "Offline probes:           $($stats.OfflineProbes)"
        "Wi-Fi but no internet:    $($stats.WifiOnlyNoInternetProbes)  <-- key signal"
        "DNS-only failures:        $($stats.DnsFailureProbes)"
        "HTTP blocked / slow:      $($stats.HttpBlockedProbes)"
        "App endpoint failures:    $($stats.AppEndpointFailureProbes)  (target: $AppEndpoint)"
        "Interface switches:       $($stats.InterfaceFlips)"
        "Longest outage (sec):     $($stats.LongestOutageSec)"
        "Over-budget cycles:       $($stats.OverBudgetCycles)"
        "Packet loss avg (lossy):  ${avgLoss}%  ($($stats.LossCycles) of $($stats.TotalProbes) cycles)"
        "ICMP latency  p50/p95/p99:  $icmpP50 / $icmpP95 / $icmpP99"
        "HTTPS latency p50/p95/p99:  $httpP50 / $httpP95 / $httpP99"
        "App   latency p50/p95/p99:  $appP50 / $appP95 / $appP99"
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
        $cycleStart = Get-Date

        # Kick off async probes in parallel
        $hPingCfBurst = Start-AsyncPingBurst -Target "1.1.1.1" -Count $PingBurstCount -TimeoutMs 1500
        $hPingGo      = Start-AsyncPing -Target "8.8.8.8" -TimeoutMs 1500
        $hDnsSys      = Start-AsyncDns -Name "cloudflare.com"
        $hHttps       = Start-AsyncHttps -Url "https://www.cloudflare.com"
        $hAppHttps    = if ($AppEndpoint) { Start-AsyncHttps -Url $AppEndpoint } else { $null }

        $iface = Get-ActiveInterface
        $wifi  = Get-WifiInfo

        $hPingGw = $null
        if ($iface -and $iface.Gateway) {
            $hPingGw = Start-AsyncPing -Target $iface.Gateway -TimeoutMs 1000
        }

        # Wait for all async tasks (max 6s total budget)
        $allTasks = @($hPingGo.Task, $hDnsSys.Task, $hHttps.Task)
        foreach ($h in $hPingCfBurst) { $allTasks += $h.Task }
        if ($hAppHttps) { $allTasks += $hAppHttps.Task }
        if ($hPingGw)   { $allTasks += $hPingGw.Task }
        try { $null = [System.Threading.Tasks.Task]::WaitAll($allTasks, 6000) } catch {}

        # Sync probe for DNS-against-specific-server (no async equivalent in .NET)
        $dnsCf = Test-DnsResolveSpecific -Name "cloudflare.com" -Server "1.1.1.1"

        # Collect results
        $pingCf  = Read-PingBurstResult -Handles $hPingCfBurst
        $pingGo  = Read-PingResult -Handle $hPingGo
        $dnsSys  = Read-DnsResult  -Handle $hDnsSys
        $https   = Read-HttpsResult -Handle $hHttps
        $appHttp = if ($hAppHttps) { Read-HttpsResult -Handle $hAppHttps } else { $null }
        $gwPing  = if ($hPingGw)   { Read-PingResult  -Handle $hPingGw  } else { $null }

        # Verdict logic
        $hasGateway   = $gwPing -and $gwPing.Ok
        $hasIcmp      = ($pingCf.Ok -or $pingGo.Ok)
        $hasHttps     = $https.Ok
        $hasDns       = ($dnsSys.Ok -or $dnsCf.Ok)
        $hasInternet  = ($hasIcmp -or $hasHttps)

        # Track consecutive failures of the application endpoint. A single failed
        # HEAD to pos.oolio.io is noise (app deploys, transient 5xx). Three in a
        # row while the rest of the internet is fine is a real app-side incident.
        if ($appHttp -and -not $appHttp.Ok) { $stats.AppEndpointFails++ } else { $stats.AppEndpointFails = 0 }

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
        } elseif ($hasHttps -and $appHttp -and -not $appHttp.Ok -and $stats.AppEndpointFails -ge 3) {
            # Generic internet works but the Oolio endpoint specifically does not.
            $verdict = "AppEndpointFailure"; $level = "ERROR"
        }

        # Fire traceroute on transition into a non-Online state
        if ($verdict -ne "Online" -and $stats.LastVerdict -eq "Online") {
            Start-TracerouteOnOutage -Target "1.1.1.1" -Reason $verdict
        }
        $stats.LastVerdict = $verdict

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
                $stats.OutageStartedAt = $cycleStart
                Write-LogLine "Outage started ($verdict)" "WARN"
            }
        }

        $stats.TotalProbes++
        switch ($verdict) {
            "Online"             { $stats.OnlineProbes++ }
            "Offline"            { $stats.OfflineProbes++ }
            "WifiOnlyNoInternet" { $stats.WifiOnlyNoInternetProbes++ }
            "DnsFailure"         { $stats.DnsFailureProbes++ }
            "HttpBlockedOrSlow"  { $stats.HttpBlockedProbes++ }
            "AppEndpointFailure" { $stats.AppEndpointFailureProbes++ }
        }
        if ($pingCf.LossPct -gt 0) {
            $stats.TotalLossPct += $pingCf.LossPct
            $stats.LossCycles++
        }
        Add-Latency -Buf $script:HttpsLatencies -Value $https.Ms
        Add-Latency -Buf $script:IcmpLatencies  -Value $pingCf.AvgMs
        if ($appHttp -and $appHttp.Ok) { Add-Latency -Buf $script:AppLatencies -Value $appHttp.Ms }

        $cycleMs = [int]((Get-Date) - $cycleStart).TotalMilliseconds

        # Console summary line
        $sigStr  = if ($wifi.SignalPct -ne $null) { "$($wifi.SignalPct)%" } else { "-" }
        $gwMs    = if ($gwPing -and $gwPing.Ok) { "$($gwPing.AvgMs)ms" } else { "FAIL" }
        $cfMs    = if ($pingCf.Ok) { "$($pingCf.AvgMs)ms" } else { "FAIL" }
        $lossStr = if ($pingCf.LossPct -gt 0) { " loss=$($pingCf.LossPct)%" } else { "" }
        $httpStr = if ($https.Ok) { "$($https.Ms)ms" } else { "FAIL" }
        $appStr  = if ($appHttp) { if ($appHttp.Ok) { "$($appHttp.Ms)ms" } else { "FAIL" } } else { "off" }
        $msg = "$verdict | iface=$ifaceName | SSID=$($wifi.SSID) sig=$sigStr | gw=$gwMs | 1.1.1.1=$cfMs$lossStr | https=$httpStr | app=$appStr | cycle=${cycleMs}ms"
        Write-LogLine $msg $level

        # CSV row
        $row = @(
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
            $VenueLabel,
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
            $dnsSys.Ok,
            $dnsSys.Ms,
            $dnsCf.Ok,
            $dnsCf.Ms,
            $pingCf.AvgMs,
            $pingCf.LossPct,
            $pingGo.AvgMs,
            $https.Ok,
            $https.Ms,
            $https.Status,
            $(if ($appHttp) { $appHttp.Ok } else { "" }),
            $(if ($appHttp) { $appHttp.Ms } else { "" }),
            $(if ($appHttp) { $appHttp.Status } else { "" }),
            $cycleMs
        ) | ForEach-Object { Csv-Escape $_ }
        Add-Content -Path $csvPath -Value ($row -join ",") -Encoding UTF8

        # Drain completed traceroutes (append to log) + poll network event log every 60s
        Drain-CompletedTraceroutes
        if (((Get-Date) - $stats.LastEventDrainAt).TotalSeconds -ge 60) {
            Drain-NetworkEvents
            $stats.LastEventDrainAt = Get-Date
        }

        # Periodic summary
        if (((Get-Date) - $stats.LastHourSummaryAt).TotalMinutes -ge $SummaryEveryMin) {
            Write-Summary
            $stats.LastHourSummaryAt = Get-Date
        }

        # Log rotation: if the .log file has grown past $LogRotateMB, rename it
        # with a -part2/-part3 suffix and continue writing to a fresh file. The
        # CSV is left alone - it's small and downstream tools prefer one file.
        try {
            $logSizeMB = [math]::Round((Get-Item $logPath -ErrorAction Stop).Length / 1MB, 1)
            if ($logSizeMB -ge $LogRotateMB) {
                $i = 2
                while (Test-Path ($logPath -replace '\.log$', "-part$i.log")) { $i++ }
                $rotated = $logPath -replace '\.log$', "-part$i.log"
                Move-Item -Path $logPath -Destination $rotated -Force
                Write-LogLine "Log rotated at ${logSizeMB}MB -> $rotated" "INFO"
            }
        } catch {}

        # Sleep the remainder of the interval. If the cycle blew the budget,
        # log a WARN and proceed immediately to the next cycle.
        $sleepSec = $IntervalSeconds - ([int]((Get-Date) - $cycleStart).TotalSeconds)
        if ($sleepSec -lt 0) {
            $stats.OverBudgetCycles++
            Write-LogLine "Cycle exceeded ${IntervalSeconds}s budget (took ${cycleMs}ms)" "WARN"
        } else {
            Start-Sleep -Seconds $sleepSec
        }
    }
} finally {
    Write-Summary -Final
    # Kill any still-pending traceroutes
    foreach ($t in $script:PendingTraceroutes) {
        try { if (-not $t.Process.HasExited) { $t.Process.Kill() } } catch {}
        Remove-Item -Path $t.File -Force -ErrorAction SilentlyContinue
    }
    try { $script:HttpClient.Dispose() } catch {}
    Write-Host "CSV saved: $csvPath" -ForegroundColor Cyan
    Write-Host "Log saved: $logPath" -ForegroundColor Cyan
}
