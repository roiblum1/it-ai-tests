#!/bin/bash
# ============================================================================
# RoCEv2 Phase-1 benchmark runner (perftest, 1-to-1 server/client).
#
#   server pod   ./roce_bench.sh server <ib_device>
#   client pod   ./roce_bench.sh client <ib_device> <server_ip> <env-label>
#
# The test matrix and its parameters come from the environment (rendered by the
# Helm chart). Server and client build an IDENTICAL plan from the same env, so
# per-test ports line up without any negotiation.
#
# Benchmark types (toggle/parameterise via env):
#   BW_READ_*  ib_read_bw     1.1   -D duration, -s sizes, -q qps
#   BW_WRITE_* ib_write_bw    1.2
#   LAT_WRITE_* ib_write_lat  1.3   -n iters, -s size, -U unsorted (raw samples)
#   LAT_READ_*  ib_read_lat   1.4
#   LAT_SEND_*  ib_send_lat   1.5
#   GPUDIRECT_ENABLED=true     1.6  re-runs the whole matrix with --use_cuda
#
# Client writes a structured run dir under $RESULTS:
#   <env-label>-<ts>/setup.json, bw/*.csv, lat/*.unsorted.txt + *.json,
#   gpudirect/{bw,lat}/... (when GPUDIRECT_ENABLED), full.log
# Graphs are produced separately by the report Job (plot_report.py).
#
# Pod needs: SR-IOV RDMA resource, IPC_LOCK, ulimit memlock unlimited; for
# GPUDirect also a GPU + CUDA-built perftest (--use_cuda).
# ============================================================================
set -u

ROLE="${1:-}"; DEV="${2:-}"

# ---- env contract (defaults keep the script runnable outside Helm) ----------
MTU="${MTU:-4096}"
RESULTS="${RESULTS:-/results}"

BW_READ_ENABLED="${BW_READ_ENABLED:-true}";   BW_READ_DURATION="${BW_READ_DURATION:-10}"
BW_READ_SIZES="${BW_READ_SIZES:-65536 1048576}"; BW_READ_QPS="${BW_READ_QPS:-8}"
BW_WRITE_ENABLED="${BW_WRITE_ENABLED:-true}"; BW_WRITE_DURATION="${BW_WRITE_DURATION:-10}"
BW_WRITE_SIZES="${BW_WRITE_SIZES:-65536 1048576}"; BW_WRITE_QPS="${BW_WRITE_QPS:-8}"

LAT_WRITE_ENABLED="${LAT_WRITE_ENABLED:-true}"; LAT_WRITE_ITERS="${LAT_WRITE_ITERS:-100000}"
LAT_WRITE_SIZE="${LAT_WRITE_SIZE:-2}";          LAT_WRITE_UNSORTED="${LAT_WRITE_UNSORTED:-true}"
LAT_READ_ENABLED="${LAT_READ_ENABLED:-true}";   LAT_READ_ITERS="${LAT_READ_ITERS:-100000}"
LAT_READ_SIZE="${LAT_READ_SIZE:-2}";            LAT_READ_UNSORTED="${LAT_READ_UNSORTED:-true}"
LAT_SEND_ENABLED="${LAT_SEND_ENABLED:-true}";   LAT_SEND_ITERS="${LAT_SEND_ITERS:-100000}"
LAT_SEND_SIZE="${LAT_SEND_SIZE:-2}";            LAT_SEND_UNSORTED="${LAT_SEND_UNSORTED:-true}"

GPUDIRECT_ENABLED="${GPUDIRECT_ENABLED:-false}"; GPU_INDEX="${GPU_INDEX:-0}"
CUDA_BIN_DIR="${CUDA_BIN_DIR:-/opt/perftest-cuda/bin}"   # CUDA-built perftest (GPUDirect)
IMAGE="${IMAGE:-unknown}"

COMMON="-R -d $DEV -m $MTU -F"   # -R rdma_cm (routed RoCEv2), -F skip CPU-freq check (pods)

banner(){ echo -e "\n========================================================\n $*\n========================================================"; }

# ---------------------------------------------------------------------------
# build_plan: fills PLAN[] identically on server and client.
# entry = subtree|family|name|port|binary|size|flags|type
#   subtree: ""=NIC results, "gpudirect"=--use_cuda results
# ---------------------------------------------------------------------------
PLAN=()
add_bw(){ # name binary enabled duration sizes qps subtree cudaflag portref
  local name="$1" bin="$2" en="$3" dur="$4" sizes="$5" qps="$6" sub="$7" cuda="$8"
  [ "$en" = true ] || return 0
  local s
  for s in $sizes; do
    PLAN+=("$sub|bw|$name|$PORT|$bin|$s|-D $dur -q $qps --report_gbits $cuda|bw")
    PORT=$((PORT+1))
  done
}
add_lat(){ # name binary enabled iters size unsorted subtree cudaflag
  local name="$1" bin="$2" en="$3" iters="$4" size="$5" uns="$6" sub="$7" cuda="$8"
  [ "$en" = true ] || return 0
  local uflag=""; [ "$uns" = true ] && uflag="-U"
  PLAN+=("$sub|lat|$name|$PORT|$bin|$size|-n $iters $uflag $cuda|lat")
  PORT=$((PORT+1))
}
build_plan(){
  PLAN=(); PORT=18000
  # pass 1: NIC (host memory)
  add_bw  read_bw  ib_read_bw  "$BW_READ_ENABLED"  "$BW_READ_DURATION"  "$BW_READ_SIZES"  "$BW_READ_QPS"  "" ""
  add_bw  write_bw ib_write_bw "$BW_WRITE_ENABLED" "$BW_WRITE_DURATION" "$BW_WRITE_SIZES" "$BW_WRITE_QPS" "" ""
  add_lat write_lat ib_write_lat "$LAT_WRITE_ENABLED" "$LAT_WRITE_ITERS" "$LAT_WRITE_SIZE" "$LAT_WRITE_UNSORTED" "" ""
  add_lat read_lat  ib_read_lat  "$LAT_READ_ENABLED"  "$LAT_READ_ITERS"  "$LAT_READ_SIZE"  "$LAT_READ_UNSORTED"  "" ""
  add_lat send_lat  ib_send_lat  "$LAT_SEND_ENABLED"  "$LAT_SEND_ITERS"  "$LAT_SEND_SIZE"  "$LAT_SEND_UNSORTED"  "" ""
  # pass 2: GPUDirect (--use_cuda) -> separate ports + gpudirect/ subtree
  if [ "$GPUDIRECT_ENABLED" = true ]; then
    local c="--use_cuda=$GPU_INDEX"
    add_bw  read_bw  ib_read_bw  "$BW_READ_ENABLED"  "$BW_READ_DURATION"  "$BW_READ_SIZES"  "$BW_READ_QPS"  gpudirect "$c"
    add_bw  write_bw ib_write_bw "$BW_WRITE_ENABLED" "$BW_WRITE_DURATION" "$BW_WRITE_SIZES" "$BW_WRITE_QPS" gpudirect "$c"
    add_lat write_lat ib_write_lat "$LAT_WRITE_ENABLED" "$LAT_WRITE_ITERS" "$LAT_WRITE_SIZE" "$LAT_WRITE_UNSORTED" gpudirect "$c"
    add_lat read_lat  ib_read_lat  "$LAT_READ_ENABLED"  "$LAT_READ_ITERS"  "$LAT_READ_SIZE"  "$LAT_READ_UNSORTED"  gpudirect "$c"
    add_lat send_lat  ib_send_lat  "$LAT_SEND_ENABLED"  "$LAT_SEND_ITERS"  "$LAT_SEND_SIZE"  "$LAT_SEND_UNSORTED"  gpudirect "$c"
  fi
}

# summarise raw -U latency samples (sorts, then picks percentiles) -> JSON
summarize_samples(){
  local f="$1"
  sort -n "$f" | awk '
    { v[NR]=$1+0; sum+=$1 }
    END{
      n=NR; if(n==0){print "{\"count\":0}"; exit}
      function pct(p,  i){ i=int(p*n); if(i<1)i=1; if(i>n)i=n; return v[i] }
      printf "{\"count\":%d,\"min\":%g,\"avg\":%.4f,\"p50\":%g,\"p99\":%g,\"p999\":%g,\"max\":%g}\n",
             n, v[1], sum/n, pct(0.50), pct(0.99), pct(0.999), v[n]
    }'
}

# ---------------------------- SERVER ----------------------------------------
if [ "$ROLE" = server ]; then
  [ -z "$DEV" ] && { echo "usage: $0 server <ib_device>"; exit 1; }
  build_plan
  echo "Listeners up on $DEV (one per test/size, matched flags). Ctrl-C to stop."
  for e in "${PLAN[@]}"; do
    IFS='|' read -r sub fam name port bin size flags type <<< "$e"
    [ "$sub" = gpudirect ] && bin="$CUDA_BIN_DIR/$bin"   # GPUDirect uses the CUDA-built perftest
    echo "  ${sub:+[gpudirect] }$name  :$port  size=$size"
    ( while true; do
        # shellcheck disable=SC2086
        $bin $COMMON -p "$port" -s "$size" $flags >/dev/null 2>&1
        sleep 1   # guard: never busy-spin on disconnect/mismatch
      done ) &
  done
  wait; exit 0
fi

# ---------------------------- CLIENT ----------------------------------------
if [ "$ROLE" = client ]; then
  TARGET="${3:-}"; LABEL="${4:-unlabeled}"
  [ -z "$DEV" ] || [ -z "$TARGET" ] && { echo "usage: $0 client <ib_device> <server_ip> <env-label>"; exit 1; }
  build_plan
  TS="$(date +%Y%m%d-%H%M%S)"
  RUNDIR="$RESULTS/${LABEL}-${TS}"
  mkdir -p "$RUNDIR/bw" "$RUNDIR/lat"
  [ "$GPUDIRECT_ENABLED" = true ] && mkdir -p "$RUNDIR/gpudirect/bw" "$RUNDIR/gpudirect/lat"
  exec > >(tee "$RUNDIR/full.log") 2>&1

  banner "RoCEv2 Phase-1 run  env=$LABEL  dev=$DEV  server=$TARGET  gpudirect=$GPUDIRECT_ENABLED"

  # ---- setup.json: what was checked + in which environment --------------------
  cat > "$RUNDIR/setup.json" <<EOF
{
  "env_label": "$LABEL",
  "role": "client",
  "device": "$DEV",
  "server_ip": "$TARGET",
  "mtu": $MTU,
  "node": "$(hostname)",
  "image": "$IMAGE",
  "date": "$(date -Is)",
  "gpudirect": $GPUDIRECT_ENABLED,
  "tests": {
    "read_bw":  {"enabled": $BW_READ_ENABLED,  "duration": $BW_READ_DURATION,  "sizes": "$BW_READ_SIZES",  "qps": $BW_READ_QPS},
    "write_bw": {"enabled": $BW_WRITE_ENABLED, "duration": $BW_WRITE_DURATION, "sizes": "$BW_WRITE_SIZES", "qps": $BW_WRITE_QPS},
    "write_lat":{"enabled": $LAT_WRITE_ENABLED,"iters": $LAT_WRITE_ITERS, "size": $LAT_WRITE_SIZE, "unsorted": $LAT_WRITE_UNSORTED},
    "read_lat": {"enabled": $LAT_READ_ENABLED, "iters": $LAT_READ_ITERS,  "size": $LAT_READ_SIZE,  "unsorted": $LAT_READ_UNSORTED},
    "send_lat": {"enabled": $LAT_SEND_ENABLED, "iters": $LAT_SEND_ITERS,  "size": $LAT_SEND_SIZE,  "unsorted": $LAT_SEND_UNSORTED}
  }
}
EOF

  for e in "${PLAN[@]}"; do
    IFS='|' read -r sub fam name port bin size flags type <<< "$e"
    [ "$sub" = gpudirect ] && bin="$CUDA_BIN_DIR/$bin"   # GPUDirect uses the CUDA-built perftest
    local_dir="$RUNDIR${sub:+/$sub}/$fam"
    banner "${sub:+[gpudirect] }$name  [$bin :$port size=$size]"
    # shellcheck disable=SC2086
    out=$($bin $COMMON -p "$port" -s "$size" $flags "$TARGET" 2>&1)
    echo "$out"

    if [ "$type" = bw ]; then
      csv="$local_dir/${name}.csv"
      [ -f "$csv" ] || echo "size_bytes,duration_s,bw_peak_gbps,bw_avg_gbps,msg_rate_mpps" > "$csv"
      read -r peak avg mr < <(echo "$out" | awk 'NF>=5 && $1 ~ /^[0-9]+$/ {p=$3;a=$4;m=$5} END{print (p==""?"NA":p),(a==""?"NA":a),(m==""?"NA":m)}')
      dur=$(echo "$flags" | sed -n 's/.*-D \([0-9]*\).*/\1/p')
      echo "$size,${dur:-NA},$peak,$avg,$mr" >> "$csv"
    else
      # latency: -U dumps raw unsorted samples (numeric-only lines)
      uns="$local_dir/${name}.unsorted.txt"
      echo "$out" | grep -E '^[0-9]+(\.[0-9]+)?$' > "$uns"
      if [ -s "$uns" ]; then
        summarize_samples "$uns" > "$local_dir/${name}.json"
      else
        # fallback: no raw samples (unsorted disabled) -> parse perftest summary row
        echo "$out" | awk 'NF>=9 && $1 ~ /^[0-9]+$/ {
          printf "{\"count\":%s,\"min\":%s,\"avg\":%s,\"p50\":\"NA\",\"p99\":%s,\"p999\":%s,\"max\":%s}\n",$2,$3,$6,$8,$9,$4 }' \
          > "$local_dir/${name}.json"
      fi
    fi
    sleep 2
  done

  banner "DONE  results in $RUNDIR  (run the report Job for graphs)"
  exit 0
fi

echo "usage:"
echo "  $0 server <ib_device>"
echo "  $0 client <ib_device> <server_ip> <env-label>"
exit 1
