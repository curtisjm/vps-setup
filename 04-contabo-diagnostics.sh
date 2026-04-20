#!/usr/bin/env bash
#
# 04-contabo-diagnostics.sh — Evaluate Contabo VPS performance
#
# PURPOSE:
#   Runs a battery of benchmarks and health checks to help decide whether
#   your Contabo node is good enough, or whether you should ask for a node
#   migration / switch to Hetzner.
#
# WHAT IT DOES:
#   1. System info (CPU, RAM, disk, kernel)
#   2. CPU steal time over a sustained period
#   3. Disk I/O benchmark (4k random reads/writes — where Contabo NVMe shows
#      its weakness vs real NVMe)
#   4. Memory bandwidth check
#   5. Network throughput and latency to common targets
#   6. Summary verdict with recommendations
#
# USAGE:
#   Run as regular user:
#     chmod +x 04-contabo-diagnostics.sh
#     ./04-contabo-diagnostics.sh
#
#   Takes about 5-10 minutes to complete.
#
# THRESHOLDS:
#   - CPU steal average > 10%: concerning, request node migration
#   - CPU steal peaks > 30%: bad node, migrate or switch providers
#   - 4k random write IOPS < 5000: disk is weak, may affect Dolt/git ops
#   - Disk latency (await) > 20ms sustained: bad, avoid data-heavy workloads

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
bad()  { echo -e "${RED}[✗]${NC} $1"; }

capture_ping_latency() {
    local host="$1"
    local output=""
    local latency=""

    output="$(ping -c 5 -q "$host" 2>/dev/null || true)"
    latency="$(printf '%s\n' "$output" | awk -F'/' 'END {print $5}')"

    [[ -n "$latency" ]] && printf '%s\n' "$latency"
    return 0
}
# end capture_ping_latency

capture_ping_packet_loss() {
    local host="$1"
    local output=""
    local loss=""

    output="$(ping -c 20 -q "$host" 2>/dev/null || true)"
    loss="$(printf '%s\n' "$output" | awk -F', ' '/packet loss/ { sub(/% packet loss.*/, "", $3); print $3; exit }')"

    [[ -n "$loss" ]] && printf '%s\n' "$loss"
    return 0
}
# end capture_ping_packet_loss

capture_cloudflare_download_speed() {
    local raw_speed=""

    raw_speed="$(curl -o /dev/null -s -w '%{speed_download}\n' \
        https://speed.cloudflare.com/__down?bytes=104857600 2>/dev/null || true)"

    if [[ "$raw_speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v bytes_per_second="$raw_speed" 'BEGIN { printf "%.1f MB/s\n", bytes_per_second/1024/1024 }'
    fi

    return 0
}
# end capture_cloudflare_download_speed

SECTION() {
    echo ""
    echo "========================================================================"
    echo "  $1"
    echo "========================================================================"
}

# Track overall verdict. We collect warnings/failures and report them
# at the end so you don't have to scroll.
VERDICT_NOTES=()

# ----------------------------------------------------------------------------
# System info
# ----------------------------------------------------------------------------

SECTION "System Information"

echo "Hostname:   $(hostname)"
echo "Uptime:     $(uptime -p)"
echo "Kernel:     $(uname -r)"
echo "OS:         $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo ""
echo "CPU:"
lscpu | grep -E "^(Model name|CPU\(s\)|Thread|Core|Socket|Vendor|CPU MHz|CPU max MHz)" | sed 's/^/  /'
echo ""
echo "Memory:"
free -h | sed 's/^/  /'
echo ""
echo "Disk:"
df -h --output=source,size,used,avail,pcent,target / | sed 's/^/  /'

# ----------------------------------------------------------------------------
# CPU steal test
# ----------------------------------------------------------------------------
# CPU steal is the single most important Contabo metric. We sample vmstat
# for 60 seconds while putting some load on the CPU (so steal actually
# matters — idle steal is meaningless).

SECTION "CPU Steal Time (60 seconds under load)"

log "Running CPU stress in background for 60 seconds..."
log "Watching the 'st' column — this is percentage of time stolen by neighbors."
echo ""

# Background stress workload. We use a simple busy loop on each core.
# If stress-ng or 'stress' is installed we could use those, but this
# avoids adding a dependency.
CORES=$(nproc)
log "Generating load on $CORES cores..."
for ((i=0; i<CORES; i++)); do
    # Infinite math loop in background — cancel with kill later
    bash -c 'while true; do echo "scale=5000; 4*a(1)" | bc -l > /dev/null; done' &
done
STRESS_PIDS=$(jobs -p)

# Install a trap so Ctrl+C (or any unexpected exit) kills the stress PIDs
# and their bc children. Without this the user ends up with a dozen bc
# processes eating 100% CPU after aborting the script.
cleanup_stress() {
    # shellcheck disable=SC2086
    [[ -n "${STRESS_PIDS:-}" ]] && kill $STRESS_PIDS 2>/dev/null || true
    # The bash loops fork `bc` as children; nuke any that outlived the loop.
    pkill -P $$ bc 2>/dev/null || true
    wait 2>/dev/null || true
}
trap 'cleanup_stress; [[ -n "${TESTFILE:-}" ]] && rm -f "${TESTFILE:-}" 2>/dev/null || true' INT TERM EXIT

# Sample vmstat for 60 seconds at 1-second intervals.
# Column 16 (space-separated) is steal time on modern kernels.
# We skip the first 2 lines (header and "since boot" summary).
STEAL_DATA=$(vmstat 1 60 | awk 'NR>2 {print $16}')

# Kill the stress workload (trap will also run on script exit)
cleanup_stress

# Compute stats
STEAL_AVG=$(echo "$STEAL_DATA" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')
STEAL_MAX=$(echo "$STEAL_DATA" | sort -n | tail -1)
STEAL_OVER_10=$(echo "$STEAL_DATA" | awk '$1 > 10 {count++} END {print count+0}')

echo ""
echo "CPU Steal Summary:"
echo "  Average:             ${STEAL_AVG}%"
echo "  Peak:                ${STEAL_MAX}%"
echo "  Seconds over 10%:    ${STEAL_OVER_10}/60"
echo ""

# Interpret the results
if (( $(echo "$STEAL_AVG > 15" | bc -l) )); then
    bad "HIGH steal average — this node is heavily contended"
    VERDICT_NOTES+=("CPU steal average ${STEAL_AVG}% is too high. Request node migration from Contabo support.")
elif (( $(echo "$STEAL_AVG > 5" | bc -l) )); then
    warn "Moderate steal — may be acceptable for API-bound workloads"
    VERDICT_NOTES+=("CPU steal average ${STEAL_AVG}% is moderate. Monitor over time.")
else
    ok "Low steal average — this node is healthy"
fi

if (( $(echo "$STEAL_MAX > 40" | bc -l) )); then
    bad "Extreme steal peaks (${STEAL_MAX}%) — node has seriously noisy neighbors"
    VERDICT_NOTES+=("CPU steal peaked at ${STEAL_MAX}%. Likely need node migration.")
fi

# ----------------------------------------------------------------------------
# Disk I/O benchmark
# ----------------------------------------------------------------------------
# Using 'dd' for a quick sequential test, then 'fio' if available for the
# more important 4k random tests. Dolt and git workloads hit 4k random
# heavily — sequential throughput is almost irrelevant.

SECTION "Disk I/O Benchmarks"

# Use a test file in /tmp (usually tmpfs) is misleading — we want to test
# the actual disk. Create in home dir.
TESTFILE="$HOME/.disktest.$$"
# Note: the INT/TERM/EXIT trap set earlier (stress cleanup section) already
# rm -f's $TESTFILE, so we don't install another trap here that would
# overwrite the stress-cleanup handler.

log "Sequential write test (1GB)..."
SEQ_WRITE=$(dd if=/dev/zero of="$TESTFILE" bs=1M count=1024 conv=fdatasync 2>&1 | tail -1)
echo "  $SEQ_WRITE"

log "Sequential read test..."
# Drop caches to get a real read (requires sudo; skip if unavailable)
sync
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || warn "Couldn't drop caches (skipped)"
SEQ_READ=$(dd if="$TESTFILE" of=/dev/null bs=1M count=1024 2>&1 | tail -1)
echo "  $SEQ_READ"

rm -f "$TESTFILE"

# fio does proper random I/O testing. Install it if not present.
if ! command -v fio &> /dev/null; then
    log "Installing fio for proper disk benchmarks..."
    sudo apt-get install -y -qq fio || warn "Could not install fio, skipping random I/O test"
fi

if command -v fio &> /dev/null; then
    log "4k random read/write test (this is the one that matters for Dolt/git)..."

    FIO_RESULT=$(fio --name=randrw --ioengine=libaio --iodepth=16 \
        --rw=randrw --bs=4k --direct=1 --size=256M \
        --numjobs=4 --runtime=30 --group_reporting --time_based \
        --filename="$HOME/.fiotest" 2>&1)

    rm -f "$HOME/.fiotest"

    READ_IOPS=$(echo "$FIO_RESULT" | grep -oP 'read:.*?IOPS=\K[0-9.kK]+' | head -1)
    WRITE_IOPS=$(echo "$FIO_RESULT" | grep -oP 'write:.*?IOPS=\K[0-9.kK]+' | head -1)

    echo ""
    echo "  4k Random Read IOPS:  $READ_IOPS"
    echo "  4k Random Write IOPS: $WRITE_IOPS"

    # Convert k/K suffix to number for comparison
    to_number() {
        local val="$1"
        if [[ "$val" =~ [kK]$ ]]; then
            echo "$(echo "${val%[kK]} * 1000" | bc)"
        else
            echo "$val"
        fi
    }

    WRITE_NUM=$(to_number "$WRITE_IOPS")
    if (( $(echo "$WRITE_NUM < 5000" | bc -l 2>/dev/null || echo 0) )); then
        warn "Low 4k write IOPS — Dolt commits and git operations will feel slow"
        VERDICT_NOTES+=("Disk 4k write IOPS ($WRITE_IOPS) is below 5k. Consider tmpfs for hot data.")
    else
        ok "Disk 4k IOPS is acceptable for Dolt/git workloads"
    fi
fi

# ----------------------------------------------------------------------------
# Memory bandwidth
# ----------------------------------------------------------------------------
# Quick and dirty check — this mostly just confirms RAM isn't misconfigured.

SECTION "Memory"

log "Memory bandwidth check..."
MEM_SPEED=$(dd if=/dev/zero of=/dev/null bs=1M count=4096 2>&1 | tail -1)
echo "  $MEM_SPEED"

# ----------------------------------------------------------------------------
# Network throughput and latency
# ----------------------------------------------------------------------------
# Ping a few common targets. High-latency or packet loss to Anthropic's
# API servers would be concerning for agent workloads.

SECTION "Network"

log "Latency to common endpoints..."
for host in api.anthropic.com api.openai.com github.com 1.1.1.1; do
    LATENCY="$(capture_ping_latency "$host")"
    if [[ -n "$LATENCY" ]]; then
        echo "  $host: ${LATENCY}ms avg"
    else
        warn "  $host: ping failed"
    fi
done

log "Checking for packet loss (20 pings to 1.1.1.1)..."
LOSS="$(capture_ping_packet_loss 1.1.1.1)"
if [[ -z "$LOSS" ]]; then
    warn "Packet loss probe failed"
    VERDICT_NOTES+=("Couldn't measure packet loss to 1.1.1.1. Re-run diagnostics when ICMP is available.")
elif [[ "$LOSS" == "0" ]]; then
    ok "No packet loss"
else
    warn "$LOSS% packet loss to 1.1.1.1"
    VERDICT_NOTES+=("Network has ${LOSS}% packet loss — could affect API reliability.")
fi

# Download speed test — use speedtest.net's CLI if we can install it,
# otherwise fall back to a simple curl download.
if ! command -v speedtest-cli &> /dev/null; then
    log "Installing speedtest-cli..."
    sudo apt-get install -y -qq speedtest-cli 2>/dev/null || warn "speedtest-cli not available"
fi

if command -v speedtest-cli &> /dev/null; then
    log "Download/upload speed test (takes ~30 seconds)..."
    speedtest-cli --simple 2>/dev/null || warn "Speedtest failed"
else
    log "Downloading 100MB from Cloudflare for a rough throughput number..."
    DOWN_SPEED="$(capture_cloudflare_download_speed)"
    if [[ -n "$DOWN_SPEED" ]]; then
        echo "  Cloudflare download: $DOWN_SPEED"
    else
        warn "Cloudflare download test failed"
    fi
fi

# ----------------------------------------------------------------------------
# Final verdict
# ----------------------------------------------------------------------------

SECTION "VERDICT"

if [[ ${#VERDICT_NOTES[@]} -eq 0 ]]; then
    ok "Your Contabo node looks healthy for AI agent workloads."
    echo ""
    echo "Recommendations:"
    echo "  - Run this script again in a few days at a different time"
    echo "    (noisy neighbors vary by time of day and day of week)"
    echo "  - Set up ongoing monitoring with netdata for long-term tracking"
else
    warn "Some issues detected:"
    echo ""
    for note in "${VERDICT_NOTES[@]}"; do
        echo "  - $note"
    done
    echo ""
    echo "Next steps:"
    echo "  1. Re-run this script at a different time of day to see if results vary"
    echo "  2. If issues persist: open a Contabo support ticket asking for node migration"
    echo "     (reference your CPU steal measurements as evidence)"
    echo "  3. If migration doesn't help: consider switching to Hetzner"
fi

echo ""
