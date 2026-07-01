#!/bin/bash
# ============================================================================
# RoCEv2 Phase-1 benchmark runner (perftest, one server <-> one client).
#
#   On the server pod:   roce_bench.sh server [device]
#   On a client pod:     roce_bench.sh client [device] <server_ip> <env-label>
#
# "device" is the in-pod RDMA device (e.g. mlx5_0). Pass "auto" or leave it empty
# to let the script find the single VF this pod owns.
#
# How the two sides stay in sync
# ------------------------------
# perftest needs the client's flags to MATCH the listening server. Instead of
# negotiating, both sides build the SAME list of tests from the SAME environment
# variables (rendered identically into every pod by the Helm chart). Because the
# list is built in a fixed order, each (test, message-size) lands on the same TCP
# port on both sides -- no coordination required.
#
# Which tests run is controlled by environment variables (toggle with *_ENABLED):
#   BW_READ_*    ib_read_bw    (1.1)  -D duration, -s sizes, -q qps
#   BW_WRITE_*   ib_write_bw   (1.2)
#   LAT_WRITE_*  ib_write_lat  (1.3)  -n iters, -s size, -U (raw samples)
#   LAT_READ_*   ib_read_lat   (1.4)
#   LAT_SEND_*   ib_send_lat   (1.5)
#   GPUDIRECT_ENABLED=true     (1.6)  re-runs the whole matrix with --use_cuda
#   GPUDIRECT_SKIP="send_lat"         tests to skip in the CUDA pass only (still on NIC)
#
# The client writes a structured run directory under $RESULTS that the report Job
# (plot_report.py) reads back:
#   <env-label>-<ts>/
#     setup.json                     what was tested + in which environment
#     bw/<test>.csv                  size,duration,bw_peak,bw_avg,msg_rate
#     lat/<test>.unsorted.txt        raw per-sample microseconds (from -U)
#     lat/<test>.json                min/avg/p50/p99/p999/max
#     gpudirect/{bw,lat}/...         same layout, when GPUDIRECT_ENABLED
#     full.log
#
# Pod requirements: an SR-IOV RDMA resource and IPC_LOCK (memlock); for GPUDirect
# also a GPU and the CUDA-built perftest (--use_cuda).
# ============================================================================
set -u

ROLE="${1:-}"
DEVICE="${2:-}"

# --- Test matrix parameters (defaults keep the script runnable outside Helm) ---
MTU="${MTU:-4096}"
RESULTS="${RESULTS:-/results}"
IMAGE="${IMAGE:-unknown}"

BW_READ_ENABLED="${BW_READ_ENABLED:-true}"
BW_READ_DURATION="${BW_READ_DURATION:-10}"
BW_READ_SIZES="${BW_READ_SIZES:-65536 1048576}"
BW_READ_QPS="${BW_READ_QPS:-8}"

BW_WRITE_ENABLED="${BW_WRITE_ENABLED:-true}"
BW_WRITE_DURATION="${BW_WRITE_DURATION:-10}"
BW_WRITE_SIZES="${BW_WRITE_SIZES:-65536 1048576}"
BW_WRITE_QPS="${BW_WRITE_QPS:-8}"

LAT_WRITE_ENABLED="${LAT_WRITE_ENABLED:-true}"
LAT_WRITE_ITERS="${LAT_WRITE_ITERS:-100000}"
LAT_WRITE_SIZE="${LAT_WRITE_SIZE:-2}"
LAT_WRITE_UNSORTED="${LAT_WRITE_UNSORTED:-true}"

LAT_READ_ENABLED="${LAT_READ_ENABLED:-true}"
LAT_READ_ITERS="${LAT_READ_ITERS:-100000}"
LAT_READ_SIZE="${LAT_READ_SIZE:-2}"
LAT_READ_UNSORTED="${LAT_READ_UNSORTED:-true}"

LAT_SEND_ENABLED="${LAT_SEND_ENABLED:-true}"
LAT_SEND_ITERS="${LAT_SEND_ITERS:-100000}"
LAT_SEND_SIZE="${LAT_SEND_SIZE:-2}"
LAT_SEND_UNSORTED="${LAT_SEND_UNSORTED:-true}"

GPUDIRECT_ENABLED="${GPUDIRECT_ENABLED:-false}"
GPU_INDEX="${GPU_INDEX:-0}"
GPUDIRECT_SKIP="${GPUDIRECT_SKIP:-send_lat}"            # tests to skip in the CUDA pass only
CUDA_BIN_DIR="${CUDA_BIN_DIR:-/opt/perftest-cuda/bin}"   # CUDA-built perftest, for --use_cuda

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
banner() {
  echo
  echo "========================================================"
  echo " $*"
  echo "========================================================"
}

# This pod owns exactly one VF, so there is exactly one RDMA device to find.
detect_rdma_device() {
  local found
  found=$(ls /sys/class/infiniband 2>/dev/null | head -n1)
  [ -z "$found" ] && found=$(ibstat -l 2>/dev/null | head -n1)   # fallback
  echo "$found"
}

# Turn raw -U latency samples into a small JSON summary (sorts, picks percentiles).
summarize_latency() {
  local samples_file="$1"
  sort -n "$samples_file" | awk '
    { value[NR] = $1 + 0; total += $1 }
    END {
      n = NR
      if (n == 0) { print "{\"count\":0}"; exit }
      function percentile(p,    i) {
        i = int(p * n); if (i < 1) i = 1; if (i > n) i = n
        return value[i]
      }
      printf "{\"count\":%d,\"min\":%g,\"avg\":%.4f,\"p50\":%g,\"p99\":%g,\"p999\":%g,\"max\":%g}\n",
             n, value[1], total / n, percentile(0.50), percentile(0.99), percentile(0.999), value[n]
    }'
}

# ----------------------------------------------------------------------------
# Build the test plan.
#
# PLAN is a list of rows, one per (test, size). Each row packs the fields below,
# separated by "|", and is built identically on the server and the client:
#
#   subtree | family | name | port | binary | size | flags | kind
#     subtree : ""        -> NIC (host memory) results
#               gpudirect -> --use_cuda results (separate ports + subdirectory)
#     family  : bw | lat  -> which subdirectory the result goes in
#     kind    : bw | lat  -> how the client parses the output
# ----------------------------------------------------------------------------
PLAN=()
NEXT_PORT=18000

add_bw_test() {   # name binary enabled duration "sizes" qps subtree cuda_flag
  local name="$1" binary="$2" enabled="$3" duration="$4" sizes="$5" qps="$6" subtree="$7" cuda="$8"
  [ "$enabled" = true ] || return 0
  local size
  for size in $sizes; do
    PLAN+=("$subtree|bw|$name|$NEXT_PORT|$binary|$size|-D $duration -q $qps --report_gbits $cuda|bw")
    NEXT_PORT=$((NEXT_PORT + 1))
  done
}

add_lat_test() {  # name binary enabled iters size unsorted subtree cuda_flag
  local name="$1" binary="$2" enabled="$3" iters="$4" size="$5" unsorted="$6" subtree="$7" cuda="$8"
  [ "$enabled" = true ] || return 0
  local unsorted_flag=""; [ "$unsorted" = true ] && unsorted_flag="-U"
  PLAN+=("$subtree|lat|$name|$NEXT_PORT|$binary|$size|-n $iters $unsorted_flag $cuda|lat")
  NEXT_PORT=$((NEXT_PORT + 1))
}

# "enabled" for the GPUDirect pass: the test's own flag AND not in GPUDIRECT_SKIP.
gpudirect_enabled_for() {   # name test_enabled
  local name="$1" enabled="$2" skip
  [ "$enabled" = true ] || { echo false; return; }
  for skip in $GPUDIRECT_SKIP; do
    [ "$skip" = "$name" ] && { echo false; return; }
  done
  echo true
}

build_test_plan() {
  PLAN=()
  NEXT_PORT=18000

  # Pass 1 -- NIC (host memory).
  add_bw_test  read_bw   ib_read_bw    "$BW_READ_ENABLED"   "$BW_READ_DURATION"  "$BW_READ_SIZES"  "$BW_READ_QPS"  "" ""
  add_bw_test  write_bw  ib_write_bw   "$BW_WRITE_ENABLED"  "$BW_WRITE_DURATION" "$BW_WRITE_SIZES" "$BW_WRITE_QPS" "" ""
  add_lat_test write_lat ib_write_lat  "$LAT_WRITE_ENABLED" "$LAT_WRITE_ITERS"   "$LAT_WRITE_SIZE" "$LAT_WRITE_UNSORTED" "" ""
  add_lat_test read_lat  ib_read_lat   "$LAT_READ_ENABLED"  "$LAT_READ_ITERS"    "$LAT_READ_SIZE"  "$LAT_READ_UNSORTED"  "" ""
  add_lat_test send_lat  ib_send_lat   "$LAT_SEND_ENABLED"  "$LAT_SEND_ITERS"    "$LAT_SEND_SIZE"  "$LAT_SEND_UNSORTED"  "" ""

  # Pass 2 -- GPUDirect: the same matrix with --use_cuda, on its own ports.
  # Tests named in GPUDIRECT_SKIP are excluded here (they still ran on the NIC).
  if [ "$GPUDIRECT_ENABLED" = true ]; then
    local cuda="--use_cuda=$GPU_INDEX"
    add_bw_test  read_bw   ib_read_bw    "$(gpudirect_enabled_for read_bw   "$BW_READ_ENABLED")"   "$BW_READ_DURATION"  "$BW_READ_SIZES"  "$BW_READ_QPS"  gpudirect "$cuda"
    add_bw_test  write_bw  ib_write_bw   "$(gpudirect_enabled_for write_bw  "$BW_WRITE_ENABLED")"  "$BW_WRITE_DURATION" "$BW_WRITE_SIZES" "$BW_WRITE_QPS" gpudirect "$cuda"
    add_lat_test write_lat ib_write_lat  "$(gpudirect_enabled_for write_lat "$LAT_WRITE_ENABLED")" "$LAT_WRITE_ITERS"   "$LAT_WRITE_SIZE" "$LAT_WRITE_UNSORTED" gpudirect "$cuda"
    add_lat_test read_lat  ib_read_lat   "$(gpudirect_enabled_for read_lat  "$LAT_READ_ENABLED")"  "$LAT_READ_ITERS"    "$LAT_READ_SIZE"  "$LAT_READ_UNSORTED"  gpudirect "$cuda"
    add_lat_test send_lat  ib_send_lat   "$(gpudirect_enabled_for send_lat  "$LAT_SEND_ENABLED")"  "$LAT_SEND_ITERS"    "$LAT_SEND_SIZE"  "$LAT_SEND_UNSORTED"  gpudirect "$cuda"
  fi
}

# Resolve the perftest binary for a plan row: the CUDA build for the gpudirect
# subtree, the plain build (on $PATH) otherwise.
binary_for() {   # subtree binary
  if [ "$1" = gpudirect ]; then echo "$CUDA_BIN_DIR/$2"; else echo "$2"; fi
}

# ----------------------------------------------------------------------------
# Resolve the device (shared by both roles), then dispatch.
# ----------------------------------------------------------------------------
case "$ROLE" in
  server|client) ;;
  *)
    echo "usage:"
    echo "  $0 server [device|auto]"
    echo "  $0 client [device|auto] <server_ip> <env-label>"
    exit 1
    ;;
esac

if [ -z "$DEVICE" ] || [ "$DEVICE" = auto ]; then
  DEVICE="$(detect_rdma_device)"
  [ -z "$DEVICE" ] && { echo "ERROR: no RDMA device found under /sys/class/infiniband"; exit 1; }
  echo "Auto-detected RDMA device: $DEVICE"
fi

# Flags every perftest invocation shares:
#   -R  use rdma_cm (routed RoCEv2)   -m  MTU   -F  skip the CPU-frequency check (pods)
COMMON="-R -d $DEVICE -m $MTU -F"

# ----------------------------------- SERVER ---------------------------------
if [ "$ROLE" = server ]; then
  build_test_plan
  echo "Listeners up on $DEVICE (one per test/size, matched flags). Ctrl-C to stop."
  for row in "${PLAN[@]}"; do
    IFS='|' read -r subtree family name port binary size flags kind <<< "$row"
    binary="$(binary_for "$subtree" "$binary")"
    echo "  ${subtree:+[gpudirect] }$name  :$port  size=$size"
    # One listener per test; restart it after each client run (never busy-spin).
    (
      while true; do
        # shellcheck disable=SC2086
        $binary $COMMON -p "$port" -s "$size" $flags >/dev/null 2>&1
        sleep 1
      done
    ) &
  done
  wait
  exit 0
fi

# ----------------------------------- CLIENT ---------------------------------
if [ "$ROLE" = client ]; then
  SERVER_IP="${3:-}"
  ENV_LABEL="${4:-unlabeled}"
  if [ -z "$SERVER_IP" ]; then
    echo "usage: $0 client <device|auto> <server_ip> <env-label>"
    exit 1
  fi

  build_test_plan

  run_dir="$RESULTS/${ENV_LABEL}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$run_dir/bw" "$run_dir/lat"
  [ "$GPUDIRECT_ENABLED" = true ] && mkdir -p "$run_dir/gpudirect/bw" "$run_dir/gpudirect/lat"
  exec > >(tee "$run_dir/full.log") 2>&1

  banner "RoCEv2 Phase-1 run  env=$ENV_LABEL  dev=$DEVICE  server=$SERVER_IP  gpudirect=$GPUDIRECT_ENABLED"

  # setup.json -- a record of what was tested and in which environment.
  cat > "$run_dir/setup.json" <<EOF
{
  "env_label": "$ENV_LABEL",
  "role": "client",
  "device": "$DEVICE",
  "server_ip": "$SERVER_IP",
  "mtu": $MTU,
  "node": "$(hostname)",
  "image": "$IMAGE",
  "date": "$(date -Is)",
  "gpudirect": $GPUDIRECT_ENABLED,
  "tests": {
    "read_bw":   {"enabled": $BW_READ_ENABLED,   "duration": $BW_READ_DURATION,  "sizes": "$BW_READ_SIZES",  "qps": $BW_READ_QPS},
    "write_bw":  {"enabled": $BW_WRITE_ENABLED,  "duration": $BW_WRITE_DURATION, "sizes": "$BW_WRITE_SIZES", "qps": $BW_WRITE_QPS},
    "write_lat": {"enabled": $LAT_WRITE_ENABLED, "iters": $LAT_WRITE_ITERS, "size": $LAT_WRITE_SIZE, "unsorted": $LAT_WRITE_UNSORTED},
    "read_lat":  {"enabled": $LAT_READ_ENABLED,  "iters": $LAT_READ_ITERS,  "size": $LAT_READ_SIZE,  "unsorted": $LAT_READ_UNSORTED},
    "send_lat":  {"enabled": $LAT_SEND_ENABLED,  "iters": $LAT_SEND_ITERS,  "size": $LAT_SEND_SIZE,  "unsorted": $LAT_SEND_UNSORTED}
  }
}
EOF

  for row in "${PLAN[@]}"; do
    IFS='|' read -r subtree family name port binary size flags kind <<< "$row"
    binary="$(binary_for "$subtree" "$binary")"
    out_dir="$run_dir${subtree:+/$subtree}/$family"
    banner "${subtree:+[gpudirect] }$name  [$binary :$port size=$size]"

    # shellcheck disable=SC2086
    output=$($binary $COMMON -p "$port" -s "$size" $flags "$SERVER_IP" 2>&1)
    echo "$output"

    if [ "$kind" = bw ]; then
      # perftest BW columns: #bytes #iters BW_peak BW_avg MsgRate
      csv="$out_dir/${name}.csv"
      [ -f "$csv" ] || echo "size_bytes,duration_s,bw_peak_gbps,bw_avg_gbps,msg_rate_mpps" > "$csv"
      read -r peak avg msg_rate < <(echo "$output" | awk '
        NF >= 5 && $1 ~ /^[0-9]+$/ { peak = $3; avg = $4; rate = $5 }
        END { print (peak == "" ? "NA" : peak), (avg == "" ? "NA" : avg), (rate == "" ? "NA" : rate) }')
      duration=$(echo "$flags" | sed -n 's/.*-D \([0-9]*\).*/\1/p')
      echo "$size,${duration:-NA},$peak,$avg,$msg_rate" >> "$csv"
    else
      # Latency: -U prints raw per-sample microseconds (numeric-only lines).
      samples="$out_dir/${name}.unsorted.txt"
      echo "$output" | grep -E '^[0-9]+(\.[0-9]+)?$' > "$samples"
      if [ -s "$samples" ]; then
        summarize_latency "$samples" > "$out_dir/${name}.json"
      else
        # No raw samples (-U disabled): fall back to perftest's own summary row.
        echo "$output" | awk 'NF >= 9 && $1 ~ /^[0-9]+$/ {
          printf "{\"count\":%s,\"min\":%s,\"avg\":%s,\"p50\":\"NA\",\"p99\":%s,\"p999\":%s,\"max\":%s}\n", $2, $3, $6, $8, $9, $4 }' \
          > "$out_dir/${name}.json"
      fi
    fi
    sleep 2
  done

  banner "DONE  results in $run_dir  (run the report Job / run_suite.sh --report for graphs)"
  exit 0
fi
