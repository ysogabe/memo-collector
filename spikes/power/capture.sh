#!/bin/bash
# Read-only bounded sampler. Authenticate in the OS/terminal; never record a password.
set -euo pipefail
out=${1:?output folder required}
samples=${2:-120}
[[ "$samples" =~ ^[0-9]+$ && "$samples" -ge 10 && "$samples" -le 900 ]] || { echo 'sample count must be 10..900' >&2; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
root=$(cd "$(dirname "$0")/../.." && pwd)
{
 date -u '+%Y-%m-%dT%H:%M:%SZ'
 sw_vers
 sysctl -n machdep.cpu.brand_string hw.memsize
 pmset -g batt
 git -C "$root" rev-parse HEAD
} > "$out/environment.txt"
# Only Apple's fixed system executable runs as root. The workload remains unprivileged.
LC_ALL=C sudo /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power --sample-rate 1000 \
 --sample-count "$samples" --format text --output-file "$out/powermetrics.txt"
python3 "$root/spikes/power/summarize.py" "$out/powermetrics.txt" "$out/power.json"
