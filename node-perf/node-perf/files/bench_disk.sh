#!/usr/bin/env bash
# ============================================================================
# bench_disk.sh -- disk benchmark via `fio`.
#   arg1 = run dir. Self-gates on DISK_ENABLED. Emits disk/metrics.json.
#
# Runs one fio job per DISK_JOBS entry ("name:rw:bs:iodepth"), always with
# --direct=1 so the page cache is bypassed and we measure the DEVICE. Each job
# is a metric dim; we record IOPS, bandwidth, and clat p50/p99 latency. Targets
# DISK_DIRECTORY (a hostPath mount of the real node disk under test).
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

RUN_DIR="${1:?run dir required}"
[ "${DISK_ENABLED:-true}" = true ] || { echo "  DISK_ENABLED=false, skipping"; exit 0; }

ENGINE="${DISK_ENGINE:-libaio}"
TIME="${DISK_TIME:-30}"
SIZE="${DISK_SIZE:-2G}"
TARGET="${DISK_DIRECTORY:-/fio-scratch}"
JOBS="${DISK_JOBS:-randread:randread:4k:32 randwrite:randwrite:4k:32}"

if ! command -v fio >/dev/null 2>&1; then
  echo "  ERROR: fio not found in image (add it to the shared Dockerfile)"; exit 1
fi
mkdir -p "$TARGET" || { echo "  ERROR: cannot create $TARGET (is diskScratch mounted?)"; exit 1; }

out="$RUN_DIR/disk"; mkdir -p "$out"

metric_begin
for spec in $JOBS; do
  IFS=: read -r name rw bs iodepth <<< "$spec"
  [ -z "$name" ] && continue
  jobjson="$out/${name}.json"
  echo "  fio: name=$name rw=$rw bs=$bs iodepth=$iodepth direct=1 dir=$TARGET"
  if ! fio --name="$name" --directory="$TARGET" --ioengine="$ENGINE" --direct=1 \
        --rw="$rw" --bs="$bs" --iodepth="$iodepth" --size="$SIZE" \
        --runtime="$TIME" --time_based --group_reporting --unlink=1 \
        --output-format=json > "$jobjson" 2>"$out/${name}.err"; then
    echo "  WARN: fio job $name failed"; sed -n '1,10p' "$out/${name}.err"; continue
  fi

  # Sum read+write sides (pure jobs have one side 0); bw KiB/s -> MiB/s;
  # clat percentiles ns -> ms, taking whichever side has data.
  read -r iops bw p50 p99 < <(jq -r '
    .jobs[0] as $j
    | [ (($j.read.iops // 0) + ($j.write.iops // 0)),
        ((($j.read.bw // 0) + ($j.write.bw // 0)) / 1024),
        (((([$j.read.clat_ns.percentile."50.000000", $j.write.clat_ns.percentile."50.000000"]
            | map(select(. != null)) | max) // 0)) / 1000000),
        (((([$j.read.clat_ns.percentile."99.000000", $j.write.clat_ns.percentile."99.000000"]
            | map(select(. != null)) | max) // 0)) / 1000000)
      ] | @tsv' "$jobjson")

  metric_add iops      "$name" "IOPS"  "$iops" true
  metric_add bandwidth "$name" "MiB/s" "$bw"   true
  metric_add clat_p50  "$name" "ms"    "$p50"  false
  metric_add clat_p99  "$name" "ms"    "$p99"  false
done
metric_flush disk fio "$out/metrics.json"
