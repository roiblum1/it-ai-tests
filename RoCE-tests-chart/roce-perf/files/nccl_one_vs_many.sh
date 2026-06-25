#!/bin/bash
# ============================================================================
# NCCL one-HCA-vs-all (1.7) across the two 1-to-1 pods.
#
#   ./nccl_one_vs_many.sh <peer_host_or_ip> [env-label]
#
# Runs the NCCL collective twice via mpirun (this pod + the peer):
#   1) NCCL_IB_HCA = <one rail>   ($NCCL_HCA_ONE)
#   2) NCCL_IB_HCA = <all rails>  ($NCCL_HCA_ALL)
# and records busbw of each into a run dir the report Job understands:
#   $RESULTS/<label>-<ts>/{setup.json, nccl/{one_hca.txt,all_hca.txt,nccl.json}}
#
# Prereqs (manual, gated by nccl.enabled): both pods run this image, sshd is up
# on BOTH pods, and key auth works between them (mount a keypair via a Secret).
# Params come from the NCCL_* env the chart renders into the pod.
# ============================================================================
set -u

PEER="${1:-}"; LABEL="${2:-nccl}"
[ -z "$PEER" ] && { echo "usage: $0 <peer_host_or_ip> [env-label]"; exit 1; }

RESULTS="${RESULTS:-/results}"
COLLECTIVE="${NCCL_COLLECTIVE:-all_reduce_perf}"
BEGIN="${NCCL_SIZE_BEGIN:-8}"; END="${NCCL_SIZE_END:-128M}"; FACTOR="${NCCL_SIZE_FACTOR:-2}"
GPUS="${NCCL_GPUS_PER_PROC:-1}"
HCA_ONE="${NCCL_HCA_ONE:-mlx5_0}"; HCA_ALL="${NCCL_HCA_ALL:-mlx5_0}"
IMAGE="${IMAGE:-unknown}"

# make sure the local launcher can ssh to the peer (peer must run sshd too)
pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null || true

# Build nccl-tests on first use. The image ships only the SOURCE because nvcc
# can't be cross-built under x86 emulation; here we are on a GPU node with a
# native nvcc, so the build works. Do this on BOTH pods before launching mpirun.
NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-/opt/nccl-tests}"
if [ ! -x "$NCCL_TESTS_DIR/build/$COLLECTIVE" ]; then
  echo "nccl-tests not built yet -> building on this node (native nvcc)..."
  make -C "$NCCL_TESTS_DIR" -j"$(nproc)" MPI=1 \
       MPI_HOME="${MPI_HOME:-/usr/lib/x86_64-linux-gnu/openmpi}" CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}" \
       NVCC_GENCODE="${NCCL_TESTS_GENCODE:--gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_90,code=sm_90}" \
    || { echo "nccl-tests build failed (need nvcc + GPU toolchain on this node)"; exit 1; }
fi

TS="$(date +%Y%m%d-%H%M%S)"
RUNDIR="$RESULTS/${LABEL}-${TS}"; mkdir -p "$RUNDIR/nccl"

run_nccl(){ # hca outfile
  local hca="$1" out="$2"
  mpirun --allow-run-as-root -np 2 -H "$(hostname),$PEER" \
    -x NCCL_IB_HCA="$hca" -x NCCL_DEBUG=WARN \
    -x LD_LIBRARY_PATH -x PATH \
    "$COLLECTIVE" -b "$BEGIN" -e "$END" -f "$FACTOR" -g "$GPUS" 2>&1 | tee "$out"
}

busbw(){ awk '/Avg bus bandwidth/ {v=$(NF)} END{print (v==""?"NA":v)}' "$1"; }

echo "NCCL $COLLECTIVE  one=$HCA_ONE  all=$HCA_ALL  peer=$PEER  -> $RUNDIR"
run_nccl "$HCA_ONE" "$RUNDIR/nccl/one_hca.txt"
run_nccl "$HCA_ALL" "$RUNDIR/nccl/all_hca.txt"
ONE="$(busbw "$RUNDIR/nccl/one_hca.txt")"; ALL="$(busbw "$RUNDIR/nccl/all_hca.txt")"

cat > "$RUNDIR/setup.json" <<EOF
{
  "env_label": "$LABEL",
  "role": "nccl",
  "peer": "$PEER",
  "image": "$IMAGE",
  "date": "$(date -Is)",
  "gpudirect": true,
  "collective": "$COLLECTIVE"
}
EOF

cat > "$RUNDIR/nccl/nccl.json" <<EOF
{"collective":"$COLLECTIVE","one":{"hca":"$HCA_ONE","busbw":$( [ "$ONE" = NA ] && echo 0 || echo "$ONE")},"all":{"hca":"$HCA_ALL","busbw":$( [ "$ALL" = NA ] && echo 0 || echo "$ALL")}}
EOF

echo "DONE  one=$ONE GB/s  all=$ALL GB/s  -> $RUNDIR/nccl/nccl.json"
