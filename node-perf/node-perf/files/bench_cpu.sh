#!/usr/bin/env bash
# ============================================================================
# bench_cpu.sh -- CPU benchmark via `sysbench cpu`.
#   arg1 = run dir. Self-gates on CPU_ENABLED. Emits cpu/metrics.json.
#
# sysbench cpu computes primes up to --cpu-max-prime; events/sec is the headline
# throughput number, plus the 95th-pct per-event latency.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

RUN_DIR="${1:?run dir required}"
[ "${CPU_ENABLED:-true}" = true ] || { echo "  CPU_ENABLED=false, skipping"; exit 0; }

THREADS="${CPU_THREADS:-0}"; [ "$THREADS" = 0 ] && THREADS="$(nproc)"
TIME="${CPU_TIME:-30}"
MAX_PRIME="${CPU_MAX_PRIME:-20000}"

out="$RUN_DIR/cpu"; mkdir -p "$out"
raw="$out/raw.txt"

echo "  sysbench cpu: threads=$THREADS time=${TIME}s max-prime=$MAX_PRIME"
sysbench cpu --threads="$THREADS" --time="$TIME" --cpu-max-prime="$MAX_PRIME" run \
  > "$raw" 2>&1 || { echo "  ERROR: sysbench cpu failed"; sed -n '1,20p' "$raw"; exit 1; }

events="$(awk '/events per second/{print $NF; exit}' "$raw")"
lat_avg="$(awk '/Latency/{f=1} f&&/avg:/{print $NF; exit}' "$raw")"
lat_p95="$(awk '/95th percentile/{print $NF; exit}' "$raw")"

metric_begin
metric_add events_per_sec ""  "events/s" "$events"  true
metric_add latency_avg    ""  "ms"       "$lat_avg" false
metric_add latency_p95    ""  "ms"       "$lat_p95" false
metric_flush cpu sysbench-cpu "$out/metrics.json"
