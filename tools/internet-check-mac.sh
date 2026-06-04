#!/usr/bin/env bash
# internet-check-mac.sh
# Continuous connectivity + Wi-Fi monitor for macOS.
# Mac equivalent of tools/Internet-Check.ps1, tuned for diagnosing intermittent
# Teams / VoIP / SaaS-app issues on Wi-Fi where the symptom is asymmetric
# packet loss rather than a clean disconnect.
#
# Usage:
#   ./internet-check-mac.sh -v "HomeOffice"
#   ./internet-check-mac.sh -v "HomeOffice" -i 3 -a "https://teams.microsoft.com"
#
# All output goes to ~/InternetCheck/logs/ by default (CSV + .log).
# Ctrl+C prints a final summary block and exits cleanly.
#
# Per cycle:
#   - Default-route interface (detects Wi-Fi vs Ethernet vs tethering)
#   - Wi-Fi RSSI / noise / SNR / tx-rate / channel / SSID / BSSID
#   - Gateway ping (separates "Wi-Fi link bad" from "internet bad")
#   - ICMP burst to 1.1.1.1 with loss%  (catches partial loss, not just outages)
#   - HTTPS HEAD to cloudflare.com with per-phase timing (DNS / TCP / TLS / TTFB)
#   - HTTPS HEAD to a configurable app endpoint (default teams.microsoft.com)
#   - DNS resolve via system resolver
#
# Verdict: Online / Offline / GatewayOnlyNoInternet / DnsFailure /
#          HttpBlockedOrSlow / AppEndpointFailure
#
# On any transition into a non-Online verdict, fires traceroute in the
# background and appends its output to the log when it completes.
#
# No sudo required. Uses only tools shipped with macOS (curl, ping, dig,
# traceroute, system_profiler, route, awk, bc).

set -u

# ---- Defaults / args -------------------------------------------------------

VENUE=""
INTERVAL=5
APP_ENDPOINT="https://teams.microsoft.com"
GENERIC_ENDPOINT="https://www.cloudflare.com"
OUT_DIR="$HOME/InternetCheck/logs"
PING_BURST=3
SUMMARY_EVERY_MIN=5

usage() {
  cat <<EOF
Usage: $0 [-v venue_label] [-i interval_sec] [-a app_url] [-o output_dir]
          [-b ping_burst_count] [-s summary_every_min] [-g generic_url]

  -v  Free-text label written into every CSV row (e.g. "Home", "Office")
  -i  Seconds between probe cycles (default 5)
  -a  HTTPS endpoint to probe in addition to cloudflare.com
      (default: $APP_ENDPOINT - the Teams web frontend)
  -g  Override the generic HTTPS control endpoint
      (default: $GENERIC_ENDPOINT)
  -o  Output directory (default: $OUT_DIR)
  -b  Number of pings per ICMP burst (default 3 - gives 0/33/67/100% loss buckets)
  -s  Periodic summary cadence in minutes (default 5)
EOF
  exit 0
}

while getopts "v:i:a:o:b:s:g:h" opt; do
  case "$opt" in
    v) VENUE="$OPTARG" ;;
    i) INTERVAL="$OPTARG" ;;
    a) APP_ENDPOINT="$OPTARG" ;;
    g) GENERIC_ENDPOINT="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    b) PING_BURST="$OPTARG" ;;
    s) SUMMARY_EVERY_MIN="$OPTARG" ;;
    h|*) usage ;;
  esac
done

mkdir -p "$OUT_DIR"

stamp="$(date +%Y-%m-%d_%H%M%S)"
host="$(scutil --get ComputerName 2>/dev/null | tr -d ' ' || hostname -s)"
slug=""
[[ -n "$VENUE" ]] && slug="$(echo "$VENUE" | tr -c 'A-Za-z0-9-' '_')-"
CSV="$OUT_DIR/internet-check-${slug}${host}-${stamp}.csv"
LOG="$OUT_DIR/internet-check-${slug}${host}-${stamp}.log"

TMP_DIR="$(mktemp -d -t internet-check.XXXXXX)"

# Stats (kept as plain variables; bash 3.2 on macOS has no associative arrays)
TOTAL=0; ONLINE=0; OFFLINE=0; GW_ONLY=0; DNS_FAIL=0
HTTP_FAIL=0; APP_FAIL=0; APP_RUN=0   # APP_RUN = consecutive app failures
IFACE_FLIPS=0; LAST_IFACE=""; LAST_VERDICT="Online"
OUTAGE_START=""; LONGEST_OUTAGE=0
LOSS_CYCLES=0; LOSS_SUM=0
RSSI_SUM=0; RSSI_N=0; RSSI_MIN=0; RSSI_MAX=-200
START_TS=$(date +%s)
LAST_SUMMARY_TS=$START_TS

# Latency ring buffers (newline-separated; trimmed to last 2000 entries)
LAT_ICMP="$TMP_DIR/lat_icmp"
LAT_HTTPS="$TMP_DIR/lat_https"
LAT_APP="$TMP_DIR/lat_app"
LAT_TLS="$TMP_DIR/lat_tls"
LAT_DNS="$TMP_DIR/lat_dns"
: >"$LAT_ICMP"; : >"$LAT_HTTPS"; : >"$LAT_APP"; : >"$LAT_TLS"; : >"$LAT_DNS"
LAT_BUF_MAX=2000

# Pending background traceroutes: list of "pid|file|reason" lines
TRACE_LIST="$TMP_DIR/traces"
: >"$TRACE_LIST"

# ---- Logging + helpers -----------------------------------------------------

log_line() {
  local lvl="$1"; shift
  local msg="$*"
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local line="[$ts][$lvl] $msg"
  local color=""
  case "$lvl" in
    OK)    color=$'\033[32m' ;;
    WARN)  color=$'\033[33m' ;;
    ERROR) color=$'\033[31m' ;;
    INFO)  color=$'\033[36m' ;;
    *)     color=$'\033[37m' ;;
  esac
  printf "%s%s%s\n" "$color" "$line" $'\033[0m'
  printf "%s\n" "$line" >>"$LOG"
}

raw_line() {
  printf "%s\n" "$*"
  printf "%s\n" "$*" >>"$LOG"
}

add_latency() {
  # add_latency <file> <value-in-ms>
  local f="$1" v="$2"
  [[ -z "$v" || "$v" == "-" ]] && return
  printf "%s\n" "$v" >>"$f"
  local n
  n=$(wc -l <"$f")
  if [[ $n -gt $LAT_BUF_MAX ]]; then
    tail -n "$LAT_BUF_MAX" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  fi
}

percentile() {
  # percentile <file> <P>   (P is 50, 95, 99 etc; integer)
  local f="$1" p="$2"
  local n; n=$(wc -l <"$f" | tr -d ' ')
  [[ $n -eq 0 ]] && { echo "-"; return; }
  local idx=$(( (p * (n - 1)) / 100 ))
  sort -n "$f" | awk -v i="$idx" 'NR==i+1 {print $0"ms"; exit}'
}

cleanup() {
  # Kill any still-running traceroutes
  if [[ -s "$TRACE_LIST" ]]; then
    while IFS='|' read -r pid file _; do
      kill "$pid" 2>/dev/null
      rm -f "$file" 2>/dev/null
    done <"$TRACE_LIST"
  fi
  write_summary "FINAL SUMMARY"
  rm -rf "$TMP_DIR"
}
trap 'cleanup; exit 0' INT TERM
trap 'cleanup' EXIT

# ---- Probe helpers ---------------------------------------------------------

get_default_interface() {
  route -n get default 2>/dev/null | awk '/interface:/ {print $2}'
}

get_default_gateway() {
  route -n get default 2>/dev/null | awk '/gateway:/ {print $2}'
}

# Cache Wi-Fi info for 20s - system_profiler is ~1s per call which is too slow
# to run every cycle, and Wi-Fi state changes more slowly than the probe interval.
WIFI_CACHE_FILE="$TMP_DIR/wifi_cache"
WIFI_CACHE_TS=0
get_wifi_info() {
  local iface="$1"
  local now; now=$(date +%s)
  if [[ $((now - WIFI_CACHE_TS)) -lt 20 && -s "$WIFI_CACHE_FILE" ]]; then
    cat "$WIFI_CACHE_FILE"; return
  fi
  local ssid="" bssid="" rssi="" noise="" tx="" ch=""
  if [[ -n "$iface" ]] && ifconfig "$iface" 2>/dev/null | grep -q "status: active"; then
    # system_profiler SPAirPortDataType works without sudo on all macOS versions.
    # ~1.5s per call - the 20s cache amortises it across ~4 probe cycles.
    # SSID/BSSID show as "<redacted>" on macOS 14+ without sudo - that's fine,
    # the diagnostic signal is in RSSI / Noise / SNR / Tx Rate, not the name.
    local sp section
    sp="$(system_profiler SPAirPortDataType 2>/dev/null)"
    # Trim to just the "Current Network Information:" block of the active iface
    section="$(awk '/Current Network Information:/{f=1; next} f && /Other Local Wi-Fi/{exit} f' <<<"$sp")"
    # SSID is the first indented line ending with ":" (often "<redacted>:")
    ssid="$(awk '/^[[:space:]]+[^[:space:]].*:[[:space:]]*$/ {sub(/:[[:space:]]*$/,""); sub(/^[[:space:]]+/,""); print; exit}' <<<"$section")"
    ch="$(awk '$1=="Channel:" {print $2; exit}' <<<"$section")"
    tx="$(awk '$1=="Transmit" && $2=="Rate:" {print $3; exit}' <<<"$section")"
    rssi="$(awk '$1=="Signal" && $2=="/" && $3=="Noise:" {print $4; exit}' <<<"$section")"
    noise="$(awk '$1=="Signal" && $2=="/" && $3=="Noise:" {print $7; exit}' <<<"$section")"
    # Floor floats to int for arithmetic
    rssi="${rssi%.*}"; noise="${noise%.*}"; tx="${tx%.*}"
  fi
  printf "%s|%s|%s|%s|%s|%s\n" "$ssid" "$bssid" "$rssi" "$noise" "$tx" "$ch" >"$WIFI_CACHE_FILE"
  WIFI_CACHE_TS=$now
  cat "$WIFI_CACHE_FILE"
}

# ICMP burst: send N pings, count successes, compute loss% + avg RTT.
ping_burst() {
  # ping_burst <target> <count> <timeout-ms>  -> "ok|avg_ms|loss_pct"
  local target="$1" count="$2" tmo_ms="$3"
  local out
  out="$(ping -c "$count" -i 0.2 -W "$tmo_ms" -q "$target" 2>/dev/null)" || true
  local recv loss avg
  recv="$(grep -oE '[0-9]+ packets received' <<<"$out" | grep -oE '^[0-9]+')"
  loss="$(grep -oE '[0-9]+(\.[0-9]+)?% packet loss' <<<"$out" | grep -oE '^[0-9]+(\.[0-9]+)?')"
  # avg = second value in "min/avg/max[/stddev] = a/b/c[/d] ms"
  avg="$(grep 'min/avg/max' <<<"$out" | awk -F'= ' '{print $2}' | awk -F'/' '{printf "%d\n", $2}')"
  [[ -z "$loss" ]] && loss=100
  [[ -z "$recv" ]] && recv=0
  if [[ "$recv" -gt 0 ]]; then
    printf "true|%s|%s\n" "${avg:-0}" "$loss"
  else
    printf "false|-|%s\n" "$loss"
  fi
}

# Single ping (for gateway). Returns "ok|ms"
ping_one() {
  local target="$1" tmo_ms="$2"
  local out
  out="$(ping -c 1 -W "$tmo_ms" -q "$target" 2>/dev/null)" || true
  if grep -qE '1 packets received' <<<"$out"; then
    local avg
    avg="$(grep 'min/avg/max' <<<"$out" | awk -F'= ' '{print $2}' | awk -F'/' '{printf "%d\n", $2}')"
    printf "true|%s\n" "${avg:-0}"
  else
    printf "false|-\n"
  fi
}

# HTTPS HEAD with per-phase timing.
# Returns: ok|total_ms|dns_ms|tcp_ms|tls_ms|ttfb_ms|http_code
https_probe() {
  local url="$1"
  local r
  r="$(curl -sS -o /dev/null -m 8 -I "$url" \
      -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n' \
      2>/dev/null)" || true
  if [[ -z "$r" ]]; then
    echo "false|-|-|-|-|-|-"; return
  fi
  read -r code t_dns t_con t_tls t_ttfb t_tot <<<"$r"
  local ms_total ms_dns ms_tcp ms_tls ms_ttfb
  ms_total=$(awk -v t="$t_tot"   'BEGIN{printf "%d", t*1000}')
  ms_dns=$(  awk -v t="$t_dns"   'BEGIN{printf "%d", t*1000}')
  ms_tcp=$(  awk -v a="$t_con" -v b="$t_dns" 'BEGIN{d=(a-b)*1000; if (d<0) d=0; printf "%d", d}')
  ms_tls=$(  awk -v a="$t_tls" -v b="$t_con" 'BEGIN{d=(a-b)*1000; if (d<0) d=0; printf "%d", d}')
  ms_ttfb=$( awk -v a="$t_ttfb" -v b="$t_tls" 'BEGIN{d=(a-b)*1000; if (d<0) d=0; printf "%d", d}')
  if [[ "$code" =~ ^[23] ]]; then
    printf "true|%s|%s|%s|%s|%s|%s\n" "$ms_total" "$ms_dns" "$ms_tcp" "$ms_tls" "$ms_ttfb" "$code"
  else
    printf "false|%s|%s|%s|%s|%s|%s\n" "$ms_total" "$ms_dns" "$ms_tcp" "$ms_tls" "$ms_ttfb" "${code:-0}"
  fi
}

dns_probe() {
  local name="$1"
  local start end
  start=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || perl -MTime::HiRes=time -e 'print int(time()*1000)')
  if dig +short +tries=1 +time=2 "$name" >/dev/null 2>&1; then
    end=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || perl -MTime::HiRes=time -e 'print int(time()*1000)')
    printf "true|%d\n" "$((end - start))"
  else
    printf "false|-\n"
  fi
}

start_traceroute() {
  local target="$1" reason="$2"
  local file="$TMP_DIR/trace-$(date +%s).txt"
  # -n: no DNS;  -w 1: 1s per probe;  -m 15: max 15 hops
  (traceroute -n -w 1 -m 15 "$target" >"$file" 2>&1) &
  local pid=$!
  printf "%s|%s|%s\n" "$pid" "$file" "$reason" >>"$TRACE_LIST"
  log_line WARN "Traceroute to $target started (reason: $reason, PID $pid)"
}

drain_traceroutes() {
  [[ ! -s "$TRACE_LIST" ]] && return
  local new="$TMP_DIR/traces.new"
  : >"$new"
  while IFS='|' read -r pid file reason; do
    if kill -0 "$pid" 2>/dev/null; then
      printf "%s|%s|%s\n" "$pid" "$file" "$reason" >>"$new"
    else
      log_line WARN "---- TRACEROUTE (reason: $reason) ----"
      while IFS= read -r ln; do raw_line "    $ln"; done <"$file"
      log_line WARN "---- end traceroute ----"
      rm -f "$file"
    fi
  done <"$TRACE_LIST"
  mv "$new" "$TRACE_LIST"
}

# ---- Summary ---------------------------------------------------------------

write_summary() {
  local title="$1"
  local now; now=$(date +%s)
  local elapsed=$(( now - START_TS ))
  local pct="0"
  [[ $TOTAL -gt 0 ]] && pct=$(awk -v o="$ONLINE" -v t="$TOTAL" 'BEGIN{printf "%.2f", (o*100)/t}')
  local avg_loss=0
  [[ $LOSS_CYCLES -gt 0 ]] && avg_loss=$(awk -v s="$LOSS_SUM" -v c="$LOSS_CYCLES" 'BEGIN{printf "%.1f", s/c}')
  local avg_rssi=" - "
  [[ $RSSI_N -gt 0 ]] && avg_rssi=$(awk -v s="$RSSI_SUM" -v n="$RSSI_N" 'BEGIN{printf "%.0f", s/n}')

  raw_line ""
  raw_line "------ $title ------"
  raw_line "Elapsed (s):              $elapsed"
  raw_line "Total probes:             $TOTAL"
  raw_line "Online probes:            $ONLINE  (${pct}% uptime)"
  raw_line "Offline probes:           $OFFLINE"
  raw_line "Gateway-only (no net):    $GW_ONLY"
  raw_line "DNS failures:             $DNS_FAIL"
  raw_line "HTTP blocked / slow:      $HTTP_FAIL"
  raw_line "App endpoint failures:    $APP_FAIL  (target: $APP_ENDPOINT)"
  raw_line "Interface switches:       $IFACE_FLIPS"
  raw_line "Longest outage (sec):     $LONGEST_OUTAGE"
  raw_line "Packet loss avg (lossy):  ${avg_loss}%  ($LOSS_CYCLES of $TOTAL cycles)"
  if [[ $RSSI_N -gt 0 ]]; then
    raw_line "Wi-Fi RSSI avg/min/max:   ${avg_rssi} / ${RSSI_MIN} / ${RSSI_MAX} dBm"
  fi
  raw_line "ICMP    p50/p95/p99:      $(percentile "$LAT_ICMP" 50) / $(percentile "$LAT_ICMP" 95) / $(percentile "$LAT_ICMP" 99)"
  raw_line "DNS     p50/p95/p99:      $(percentile "$LAT_DNS" 50) / $(percentile "$LAT_DNS" 95) / $(percentile "$LAT_DNS" 99)"
  raw_line "TLS hs  p50/p95/p99:      $(percentile "$LAT_TLS" 50) / $(percentile "$LAT_TLS" 95) / $(percentile "$LAT_TLS" 99)"
  raw_line "HTTPS   p50/p95/p99:      $(percentile "$LAT_HTTPS" 50) / $(percentile "$LAT_HTTPS" 95) / $(percentile "$LAT_HTTPS" 99)"
  raw_line "App     p50/p95/p99:      $(percentile "$LAT_APP" 50) / $(percentile "$LAT_APP" 95) / $(percentile "$LAT_APP" 99)"
  raw_line "----------------------"
  raw_line ""
}

# ---- Header + self-test ----------------------------------------------------

venue_display="${VENUE:-(unset - pass -v to tag this run)}"
raw_line "$(printf '=%.0s' $(seq 1 78))"
raw_line "Internet connectivity monitor (macOS)"
raw_line "Venue:      $venue_display"
raw_line "Computer:   $host"
raw_line "Started:    $(date '+%Y-%m-%d %H:%M:%S')"
raw_line "Interval:   ${INTERVAL}s    Burst: $PING_BURST    Summary every: ${SUMMARY_EVERY_MIN}min"
raw_line "Generic:    $GENERIC_ENDPOINT"
raw_line "App probe:  $APP_ENDPOINT"
raw_line "CSV log:    $CSV"
raw_line "Text log:   $LOG"
raw_line "Press Ctrl+C to stop and print summary."
raw_line "$(printf '=%.0s' $(seq 1 78))"

log_line INFO "Running self-test..."
for tool in curl ping dig traceroute route awk system_profiler; do
  if command -v "$tool" >/dev/null 2>&1; then
    log_line OK "  $tool: $(command -v "$tool")"
  else
    log_line WARN "  $tool: NOT FOUND"
  fi
done
iface="$(get_default_interface)"; gw="$(get_default_gateway)"
log_line OK "  Default route: ${iface:-none} via ${gw:-none}"
wifi_init="$(get_wifi_info "$iface")"
IFS='|' read -r init_ssid init_bssid init_rssi init_noise init_tx init_ch <<<"$wifi_init"
if [[ -n "$init_ssid" ]]; then
  log_line OK "  Wi-Fi: SSID='$init_ssid' RSSI=${init_rssi}dBm Noise=${init_noise}dBm Tx=${init_tx}Mbps Ch=$init_ch"
else
  log_line WARN "  Wi-Fi: no SSID (interface may be Ethernet or system_profiler returned nothing)"
fi
log_line OK "Self-test passed."

# CSV header
echo "Timestamp,Venue,Verdict,Interface,Gateway,SSID,BSSID,RSSI,Noise,SNR,TxMbps,Channel,GwPingMs,PingCfMs,PingCfLossPct,DnsOk,DnsMs,HttpsOk,HttpsMs,HttpsDnsMs,HttpsTcpMs,HttpsTlsMs,HttpsTtfbMs,HttpsCode,AppOk,AppMs,AppCode,CycleMs" >"$CSV"

# ---- Main loop -------------------------------------------------------------

while true; do
  cycle_start=$(date +%s)

  iface="$(get_default_interface)"
  gw="$(get_default_gateway)"
  IFS='|' read -r ssid bssid rssi noise tx_rate channel <<<"$(get_wifi_info "$iface")"
  snr=""
  if [[ -n "$rssi" && -n "$noise" ]]; then
    snr=$(( rssi - noise ))
  fi

  # Track RSSI for the summary (only when we actually have a number)
  if [[ -n "$rssi" && "$rssi" =~ ^-?[0-9]+$ ]]; then
    RSSI_SUM=$(( RSSI_SUM + rssi ))
    RSSI_N=$(( RSSI_N + 1 ))
    [[ $RSSI_N -eq 1 || $rssi -lt $RSSI_MIN ]] && RSSI_MIN=$rssi
    [[ $rssi -gt $RSSI_MAX ]] && RSSI_MAX=$rssi
  fi

  # Probes in parallel, results to temp files
  ( ping_burst "1.1.1.1" "$PING_BURST" 1500 ) >"$TMP_DIR/pcf" &
  pid_pcf=$!
  if [[ -n "$gw" ]]; then
    ( ping_one "$gw" 1000 ) >"$TMP_DIR/pgw" &
    pid_pgw=$!
  else
    echo "false|-" >"$TMP_DIR/pgw"; pid_pgw=""
  fi
  ( https_probe "$GENERIC_ENDPOINT" ) >"$TMP_DIR/https" &
  pid_https=$!
  ( https_probe "$APP_ENDPOINT" )     >"$TMP_DIR/app" &
  pid_app=$!
  ( dns_probe   "cloudflare.com" )    >"$TMP_DIR/dns" &
  pid_dns=$!

  wait $pid_pcf $pid_https $pid_app $pid_dns 2>/dev/null
  [[ -n "$pid_pgw" ]] && wait $pid_pgw 2>/dev/null

  IFS='|' read -r pcf_ok pcf_ms pcf_loss <"$TMP_DIR/pcf"
  # macOS ping reports loss as e.g. "0.0" or "33.3" - floor to int for arithmetic
  pcf_loss="${pcf_loss%.*}"; [[ -z "$pcf_loss" ]] && pcf_loss=0
  IFS='|' read -r pgw_ok pgw_ms <"$TMP_DIR/pgw"
  IFS='|' read -r https_ok https_ms https_dns_ms https_tcp_ms https_tls_ms https_ttfb_ms https_code <"$TMP_DIR/https"
  IFS='|' read -r app_ok app_ms app_dns_ms app_tcp_ms app_tls_ms app_ttfb_ms app_code <"$TMP_DIR/app"
  IFS='|' read -r dns_ok dns_ms <"$TMP_DIR/dns"

  # Verdict
  has_gw="$pgw_ok"
  has_icmp="$pcf_ok"
  has_https="$https_ok"
  has_dns="$dns_ok"
  has_internet="false"
  [[ "$has_icmp" == "true" || "$has_https" == "true" ]] && has_internet="true"

  if [[ "$app_ok" != "true" ]]; then APP_RUN=$((APP_RUN+1)); else APP_RUN=0; fi

  verdict="Online"; level="OK"
  if [[ "$has_internet" == "false" && "$has_gw" != "true" ]]; then
    verdict="Offline"; level="ERROR"
  elif [[ "$has_internet" == "false" && "$has_gw" == "true" ]]; then
    verdict="GatewayOnlyNoInternet"; level="ERROR"
  elif [[ "$has_dns" != "true" && "$has_icmp" == "true" ]]; then
    verdict="DnsFailure"; level="WARN"
  elif [[ "$has_https" != "true" && "$has_icmp" == "true" ]]; then
    verdict="HttpBlockedOrSlow"; level="WARN"
  elif [[ "$has_https" == "true" && "$app_ok" != "true" && $APP_RUN -ge 3 ]]; then
    verdict="AppEndpointFailure"; level="ERROR"
  fi

  # Fire traceroute on entry into non-Online state
  if [[ "$verdict" != "Online" && "$LAST_VERDICT" == "Online" ]]; then
    start_traceroute "1.1.1.1" "$verdict"
  fi
  LAST_VERDICT="$verdict"

  # Track interface flips
  iface_name="${iface:-none}"
  if [[ -n "$LAST_IFACE" && "$LAST_IFACE" != "$iface_name" ]]; then
    IFACE_FLIPS=$((IFACE_FLIPS+1))
    log_line WARN "Interface switched: $LAST_IFACE -> $iface_name"
  fi
  LAST_IFACE="$iface_name"

  # Outage duration tracking
  if [[ "$verdict" == "Online" ]]; then
    if [[ -n "$OUTAGE_START" ]]; then
      outage_sec=$(( $(date +%s) - OUTAGE_START ))
      log_line OK "Outage ended after ${outage_sec}s"
      [[ $outage_sec -gt $LONGEST_OUTAGE ]] && LONGEST_OUTAGE=$outage_sec
      OUTAGE_START=""
    fi
  else
    [[ -z "$OUTAGE_START" ]] && { OUTAGE_START=$cycle_start; log_line WARN "Outage started ($verdict)"; }
  fi

  # Counters
  TOTAL=$((TOTAL+1))
  case "$verdict" in
    Online)                 ONLINE=$((ONLINE+1)) ;;
    Offline)                OFFLINE=$((OFFLINE+1)) ;;
    GatewayOnlyNoInternet)  GW_ONLY=$((GW_ONLY+1)) ;;
    DnsFailure)             DNS_FAIL=$((DNS_FAIL+1)) ;;
    HttpBlockedOrSlow)      HTTP_FAIL=$((HTTP_FAIL+1)) ;;
    AppEndpointFailure)     APP_FAIL=$((APP_FAIL+1)) ;;
  esac
  if [[ -n "$pcf_loss" && "$pcf_loss" != "0" ]]; then
    LOSS_CYCLES=$((LOSS_CYCLES+1))
    LOSS_SUM=$((LOSS_SUM + pcf_loss))
  fi
  [[ "$pcf_ms"   != "-" ]] && add_latency "$LAT_ICMP"  "$pcf_ms"
  [[ "$https_ms" != "-" && "$https_ok" == "true" ]] && add_latency "$LAT_HTTPS" "$https_ms"
  [[ "$app_ms"   != "-" && "$app_ok"   == "true" ]] && add_latency "$LAT_APP"   "$app_ms"
  [[ "$https_tls_ms" != "-" && "$https_ok" == "true" ]] && add_latency "$LAT_TLS"  "$https_tls_ms"
  [[ "$dns_ms"   != "-" && "$dns_ok"   == "true" ]] && add_latency "$LAT_DNS"   "$dns_ms"

  cycle_ms=$(( ($(date +%s) - cycle_start) * 1000 ))

  # Console + log line
  wifi_str="-"
  if [[ -n "$ssid" ]]; then
    wifi_str="ssid=$ssid rssi=${rssi:-?}dBm snr=${snr:-?}dB tx=${tx_rate:-?}M"
  fi
  loss_str=""
  [[ "$pcf_loss" != "0" && -n "$pcf_loss" ]] && loss_str=" loss=${pcf_loss}%"
  gw_str="FAIL"; [[ "$pgw_ok" == "true" ]] && gw_str="${pgw_ms}ms"
  cf_str="FAIL"; [[ "$pcf_ok" == "true" ]] && cf_str="${pcf_ms}ms"
  https_str="FAIL"; [[ "$https_ok" == "true" ]] && https_str="${https_ms}ms(tls=${https_tls_ms}ms)"
  app_str="FAIL";   [[ "$app_ok"   == "true" ]] && app_str="${app_ms}ms"
  log_line "$level" "$verdict | iface=$iface_name | $wifi_str | gw=$gw_str | 1.1.1.1=$cf_str$loss_str | https=$https_str | app=$app_str | cycle=${cycle_ms}ms"

  # CSV row
  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$VENUE" "$verdict" "$iface_name" "$gw" \
    "$ssid" "$bssid" "${rssi:-}" "${noise:-}" "${snr:-}" "${tx_rate:-}" "${channel:-}" \
    "$pgw_ms" "$pcf_ms" "$pcf_loss" \
    "$dns_ok" "$dns_ms" \
    "$https_ok" "$https_ms" "$https_dns_ms" "$https_tcp_ms" "$https_tls_ms" "$https_ttfb_ms" "$https_code" \
    "$app_ok" "$app_ms" "$app_code" \
    "$cycle_ms" >>"$CSV"

  drain_traceroutes

  # Periodic summary
  if [[ $(( $(date +%s) - LAST_SUMMARY_TS )) -ge $((SUMMARY_EVERY_MIN * 60)) ]]; then
    write_summary "Periodic summary"
    LAST_SUMMARY_TS=$(date +%s)
  fi

  sleep_for=$(( INTERVAL - ($(date +%s) - cycle_start) ))
  [[ $sleep_for -gt 0 ]] && sleep $sleep_for
done
