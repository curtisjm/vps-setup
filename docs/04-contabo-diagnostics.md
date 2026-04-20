# `04-contabo-diagnostics.sh` — Benchmark for noisy neighbors

**Run as:** regular user with `sudo` (for dropping page cache and installing `fio`/`speedtest-cli` on demand).
**Goal:** produce a quick, honest health report for a Contabo (or any) VPS focused on the metrics that actually matter for AI agent workloads: CPU steal, 4 k random IOPS, basic memory/network sanity.

Takes ~5–10 minutes. Designed to be run multiple times of day across a week — noisy-neighbor issues are bursty, not constant.

## What it does in detail

1. **System info.** Prints hostname, uptime, kernel, OS, `lscpu` extract, `free -h`, `df -h /`. No interpretation, just facts-for-the-log.
2. **CPU steal test (60 seconds under load).** This is the single most important Contabo metric. Idle steal is meaningless; steal is only defined relative to time the guest wanted the CPU. The script:
   - Spawns N background busy loops (one per logical core) that run `echo "scale=5000; 4*a(1)" | bc -l` in a `while true`. Pure CPU, no syscalls, no disk — picks up every bit of contention the hypervisor throws at you.
   - Installs a trap on `INT/TERM/EXIT` so Ctrl-C doesn't leave orphan `bc` processes pegging your cores after abort. The trap `kill`s the direct children plus any `bc` grandchildren (`pkill -P $$ bc`).
   - Runs `vmstat 1 60` concurrently, awks out the 16th column (steal), computes average, max, and count-of-seconds-above-10-pct.
   - Verdicts: avg > 15 % → "request node migration", avg > 5 % → "monitor", max > 40 % → "extreme peaks, likely migration".
3. **Disk I/O benchmark.** Writes a 1 GB test file in `$HOME` (not `/tmp`, which is often tmpfs and would hide real disk performance). Sequential-write + sequential-read via `dd` with `conv=fdatasync` and `sync; echo 3 > drop_caches` between — gives you a baseline sequential number. Then installs `fio` if missing and runs:
   ```
   fio --name=randrw --ioengine=libaio --iodepth=16 --rw=randrw
       --bs=4k --direct=1 --size=256M --numjobs=4 --runtime=30
       --group_reporting --time_based
   ```
   The 4 k random numbers are the ones that matter. Dolt commits, git `status`/`add`/`commit`, SQLite writes — all of it is 4 k random I/O. Sequential throughput is mostly irrelevant. The script parses `IOPS=...` from the output, converts `k`/`K` suffixes, and verdicts: write IOPS < 5k → "low, consider tmpfs for hot data". The earlier TESTFILE cleanup is handled by the combined INT/TERM/EXIT trap installed in the steal section, so it survives Ctrl-C during this phase.
4. **Memory bandwidth.** Crude `dd if=/dev/zero of=/dev/null bs=1M count=4096` — really just confirms RAM isn't misconfigured and the kernel isn't doing something weird. Not a real memory benchmark.
5. **Network.** Pings 4 targets at 5 packets each: `api.anthropic.com`, `api.openai.com`, `github.com`, `1.1.1.1`. Averages are the interesting number for agent workloads (the API hosts). Then 20 pings to 1.1.1.1 for packet-loss check; non-zero loss is flagged. Attempts `speedtest-cli` for actual throughput, falls back to a timed 100 MB Cloudflare download. If ICMP or the fallback download fails, the script now warns and keeps going instead of aborting under `set -e`.
6. **Verdict summary.** Accumulates flags into `VERDICT_NOTES[]` during the run and prints them at the end, so you don't have to scroll back through the log. If clean, recommends rerunning at a different time of day and setting up ongoing monitoring (e.g. Netdata).

## Replicate manually (no script)

```bash
# --- CPU steal under sustained load ---
CORES=$(nproc)
# Fire up busy loops, capture PIDs
for _ in $(seq 1 $CORES); do
    bash -c 'while true; do echo "scale=5000; 4*a(1)" | bc -l > /dev/null; done' &
done
STRESS_PIDS=$(jobs -p)
# Sample vmstat for 60s; column 16 is steal time
vmstat 1 60 | awk 'NR>2 {sum+=$16; if ($16>max) max=$16; n++} END {printf "avg=%.1f max=%d\n", sum/n, max}'
# Clean up
kill $STRESS_PIDS 2>/dev/null
pkill -P $$ bc 2>/dev/null
wait

# --- Sequential disk I/O ---
TEST=~/.disktest.$$
dd if=/dev/zero of="$TEST" bs=1M count=1024 conv=fdatasync
sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
dd if="$TEST" of=/dev/null bs=1M count=1024
rm -f "$TEST"

# --- 4k random I/O (the one that matters) ---
sudo apt-get install -y fio
fio --name=randrw --ioengine=libaio --iodepth=16 --rw=randrw --bs=4k \
    --direct=1 --size=256M --numjobs=4 --runtime=30 \
    --group_reporting --time_based --filename=~/.fiotest
rm -f ~/.fiotest

# --- Ping important endpoints ---
for h in api.anthropic.com api.openai.com github.com 1.1.1.1; do
    ping -c 5 -q "$h" | awk -F'/' 'END {print "'"$h"' avg:", $5, "ms"}'
done

# --- Packet loss ---
ping -c 20 -q 1.1.1.1 | grep -oP '\d+(?=% packet loss)'

# --- Throughput ---
sudo apt-get install -y speedtest-cli
speedtest-cli --simple
# Or, a quick Cloudflare check:
curl -o /dev/null -s -w '%{speed_download}\n' \
    https://speed.cloudflare.com/__down?bytes=104857600
```

## Interpreting the numbers

| Metric | Good | Concerning | Bad |
|---|---|---|---|
| CPU steal avg | < 5 % | 5–15 % | > 15 % |
| CPU steal peak | < 20 % | 20–40 % | > 40 % |
| 4k random write IOPS | > 10k | 5k–10k | < 5k |
| Ping to api.anthropic.com | < 50 ms | 50–150 ms | > 200 ms |
| Packet loss to 1.1.1.1 | 0 % | < 1 % | > 1 % |

Steal above 15 % sustained is the "open a Contabo ticket" threshold. In their support flow, citing vmstat evidence usually gets you migrated to a less-contended node without much pushback.

## Why this way

- **`bc` busy loop, not `stress-ng`.** Zero extra install, portable, and the CPU pressure is what matters — the hypervisor doesn't care whether your workload is bignum arithmetic or benchmarking code. `bc` is already a dependency of `01-install-dev-tools.sh` for this exact reason.
- **4 k random IOPS, not sequential.** Real-world Dolt/git/SQLite workloads are dominated by small random writes. Advertised "NVMe speeds" on oversold providers are sequential numbers that look great and tell you almost nothing about how your DB commit will feel.
- **`libaio` + `iodepth=16` + `--direct=1`.** Matches how a DB actually exercises the disk (async queued I/O, bypassing page cache). A synchronous dd-only test drastically undersells both the good and bad cases.
- **Tests done in `$HOME`, not `/tmp`.** On many Ubuntu images `/tmp` is tmpfs (RAM). Testing there tells you about your RAM, not your disk.
- **`sync; echo 3 > drop_caches`** before sequential read — otherwise you're measuring page cache hit, not disk.
- **INT/TERM/EXIT trap.** Without it, Ctrl-C during the stress phase leaves `N` infinite-loop `bash` processes running, each forking `bc`, eating 100 % CPU until you notice and `pkill` them yourself. Been there.
- **No-verdict mode for the summary block.** Rather than inline pass/fail per test (which scrolls off screen), accumulate notes and print at end. You always see the final verdict regardless of how much log came before.

## Known gotchas

- **Single-run numbers are noisy.** Noisy-neighbor behaviour is bursty; one run looking fine doesn't prove the VPS is healthy. Run it 4–5 times across different hours of a week before drawing conclusions.
- **`sudo` required for the cache drop.** If sudo fails, the sequential-read number is measuring cache, not disk. The script warns if drop_caches fails.
- **`fio` install requires apt to be working.** If the script fails to install fio (unusual), the 4 k random test is skipped and the 4 k verdict lines won't fire. You'll see a warning and the rest of the script continues.
- **Download speed test fallback.** `speedtest-cli` sometimes can't pick a server (their infra hiccups); the Cloudflare fallback usually works but measures only Cloudflare, not arbitrary egress. If either network probe fails, the script warns and continues so you still get the CPU/disk verdicts.
- **The tests don't touch disk where Gas Town actually lives.** If you symlinked `~/gt/.dolt-data` to a tmpfs, the `$HOME`-based disk test still hits the real disk — which is probably what you want for the benchmark, but worth understanding.
