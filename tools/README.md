# Tools

Standalone scripts that don't depend on the main toolkit. Copy individual files to a flash drive or paste into a remote support session.

## Internet-Check.ps1

24-hour connectivity monitor for a Windows POS terminal. Designed for the case where Wi-Fi stays up but the internet drops and the 4G fallback doesn't kick in — captures the data you need to take to the venue's network person.

### Run

```powershell
# From a PowerShell window opened in the script's folder
.\Internet-Check.ps1
```

Or right-click → **Run with PowerShell**. Defaults to 10-second probes.

To stop, press **Ctrl+C** in the window. A summary is printed and saved.

### What it captures (per probe)

- **Active default-route interface** — so you can prove whether 4G ever took over the default route, or whether Wi-Fi held it the whole time.
- **Wi-Fi state** — SSID, BSSID, signal %, TX rate (from `netsh wlan show interfaces`).
- **Default gateway ping** — separates "Wi-Fi dropped" from "internet dropped".
- **DNS resolution** — against the system resolver *and* Cloudflare `1.1.1.1`, so you can spot a DNS-only outage.
- **ICMP** to `1.1.1.1` and `8.8.8.8` (3 pings each, average + loss %).
- **HTTPS** HEAD request to `www.cloudflare.com` — some networks block ICMP entirely, so HTTPS is the real test.

### Verdict per probe

- **Online** — internet works
- **WifiOnlyNoInternet** — gateway pings but external traffic fails (this is the smoking gun for the user's hypothesis)
- **Offline** — gateway also unreachable
- **DnsFailure** — pings work but DNS broken
- **HttpBlockedOrSlow** — pings work but HTTPS fails

### Outputs

In the same folder as the script:

- `internet-check-<computer>-<timestamp>.csv` — one row per probe. Opens cleanly in Excel.
- `internet-check-<computer>-<timestamp>.log` — human-readable, timestamped log with [OK]/[WARN]/[ERROR] tags.

### Summary

Printed to the console + appended to the log every hour, and a final summary on Ctrl+C:

- Total probes, online probes, % uptime
- Offline probe count, **Wi-Fi-but-no-internet probe count** (key signal)
- DNS-only failure count
- Interface switches (proves whether 4G fallback ever activated)
- Longest single outage in seconds

### Options

```powershell
.\Internet-Check.ps1 -IntervalSeconds 30      # default is 10
.\Internet-Check.ps1 -OutputFolder C:\Temp    # default is the script's folder
```

### What to hand the network person

The CSV. Filter to `Verdict <> Online` in Excel and you'll see exactly when outages happened, what the Wi-Fi signal was at the moment, and whether the gateway was reachable. That's enough to start a conversation about whether it's an AP / ISP / 4G-failover issue.
