#!/usr/bin/env bash
# ============================================================================
# bench_mem.sh -- memory benchmark via `sysbench memory`.
#   arg1 = run dir. Self-gates on MEM_ENABLED. Emits mem/metrics.json.
#
# Runs the cross product of oper (read/write) x mode (seq/rnd). Each combo is a
# metric dim (e.g. "read-seq"); throughput MiB/s is the headline, plus 95th-pct
# latency.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

RUN_DIR="${1:?run dir required}"
[ "${MEM_ENABLED:-true}" = true ] || { echo "  MEM_ENABLED=false, skipping"; exit 0; }

THREADS="${MEM_THREADS:-0}"; [ "$THREADS" = 0 ] && THREADS="$(nproc)"
TIME="${MEM_TIME:-30}"
BLOCK="${MEM_BLOCK_SIZE:-1M}"
TOTAL="${MEM_TOTAL_SIZE:-100G}"
OPERS="${MEM_OPER:-read write}"
MODES="${MEM_MODE:-seq rnd}"

out="$RUN_DIR/mem"; mkdir -p "$out"
raw="$out/raw.txt"
: > "$raw"

metric_begin
for oper in $OPERS; do
  for mode in $MODES; do
    dim="${oper}-${mode}"
    echo "  sysbench memory: oper=$oper mode=$mode threads=$THREADS block=$BLOCK"
    echo "===== $dim =====" >> "$raw"
    log="$(sysbench memory --threads="$THREADS" --time="$TIME" \
      --memory-block-size="$BLOCK" --memory-total-size="$TOTAL" \
      --memory-oper="$oper" --memory-access-mode="$mode" run 2>&1)"
    printf '%s\n\n' "$log" >> "$raw"

    # "1234.56 MiB transferred (1234.56 MiB/sec)" -> the value before MiB/sec.
    tput="$(printf '%s\n' "$log" | awk '{gsub(/[()]/," ")} /MiB\/sec/{for(i=1;i<=NF;i++) if($i=="MiB/sec"){print $(i-1); exit}}')"
    lat_p95="$(printf '%s\n' "$log" | awk '/95th percentile/{print $NF; exit}')"

    metric_add throughput  "$dim" "MiB/s" "$tput"    true
    metric_add latency_p95 "$dim" "ms"    "$lat_p95" false
  done
done
metric_flush mem sysbench-memory "$out/metrics.json"
