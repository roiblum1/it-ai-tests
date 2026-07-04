#!/bin/bash
# ============================================================================
# NCCL one-HCA-vs-all (1.7), launched from this pod against a peer pod.
#
#   ./nccl_one_vs_many.sh <peer_pod_ip> [env-label]   # run the test
#   ./nccl_one_vs_many.sh build                        # just build nccl-tests
#
# Runs the NCCL collective twice via mpirun (this pod + the peer):
#   1) NCCL_IB_HCA = <one rail>   ($NCCL_HCA_ONE)
#   2) NCCL_IB_HCA = <all rails>  ($NCCL_HCA_ALL)
# and records busbw of each into a run dir the report understands:
#   $RESULTS/<label>-<ts>/{setup.json, nccl/{one_hca.txt,all_hca.txt,nccl.json}}
#
# run_suite.sh --nccl handles the prereqs: sshd + passwordless key auth between
# the two pods, and `... build` on BOTH pods. RoCE tuning (GID index, socket
# iface, IB disable, debug) comes from the NCCL_*_CFG env the chart renders; we
# resolve them and pass them to every rank with `mpirun -x`.
# ============================================================================
set -u

PEER="${1:-}"; LABEL="${2:-nccl}"
[ -z "$PEER" ] && { echo "usage: $0 <peer_pod_ip|build> [env-label]"; exit 1; }

RESULTS="${RESULTS:-/results}"
COLLECTIVE="${NCCL_COLLECTIVE:-all_reduce_perf}"
BEGIN="${NCCL_SIZE_BEGIN:-8}"; END="${NCCL_SIZE_END:-128M}"; FACTOR="${NCCL_SIZE_FACTOR:-2}"
GPUS="${NCCL_GPUS:-1}"
IMAGE="${IMAGE:-unknown}"

# RoCE tuning (chart renders *_CFG so the literal "auto" never leaks into NCCL).
GID_CFG="${NCCL_IB_GID_INDEX_CFG:-auto}"
SOCK_IFNAME="${NCCL_SOCKET_IFNAME_CFG:-eth0}"
IB_DISABLE="${NCCL_IB_DISABLE_CFG:-0}"
DEBUG="${NCCL_DEBUG_CFG:-WARN}"

NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-/opt/nccl-tests}"

# Build nccl-tests on first use. The image ships only the SOURCE (nvcc can't
# cross-build under x86 emulation); on a GPU node the native nvcc works. compute_90
# PTX also JIT-forward-runs on Blackwell (B200/B300).
build_nccl_tests() {
  [ -x "$NCCL_TESTS_DIR/build/$COLLECTIVE" ] && return 0
  echo "nccl-tests not built yet -> building on this node (native nvcc)..."
  make -C "$NCCL_TESTS_DIR" -j"$(nproc)" MPI=1 \
       MPI_HOME="${MPI_HOME:-/usr/lib/x86_64-linux-gnu/openmpi}" CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}" \
       NVCC_GENCODE="${NCCL_TESTS_GENCODE:--gencode=arch=compute_90,code=sm_90 -gencode=arch=compute_90,code=compute_90}" \
    || { echo "nccl-tests build failed (need nvcc + GPU toolchain on this node)"; exit 1; }
}

build_nccl_tests
[ "$PEER" = build ] && { echo "build-only: nccl-tests ready at $NCCL_TESTS_DIR/build"; exit 0; }

# HCA list -- gather the pod's actual RDMA devices instead of hardcoding rails.
detect_hcas() { ls /sys/class/infiniband 2>/dev/null | sort | paste -sd, - ; }
HCA_ALL="${NCCL_HCA_ALL:-auto}"; HCA_ONE="${NCCL_HCA_ONE:-auto}"
if [ -z "$HCA_ALL" ] || [ "$HCA_ALL" = auto ]; then HCA_ALL="$(detect_hcas)"; fi
if [ -z "$HCA_ONE" ] || [ "$HCA_ONE" = auto ]; then HCA_ONE="${HCA_ALL%%,*}"; fi
[ -z "$HCA_ALL" ] && { echo "no RDMA devices found under /sys/class/infiniband"; exit 1; }

# Resolve the RoCEv2 GID index of the first rail from sysfs (no show_gids/MOFED
# dependency): the gid_attrs/types/<index> file that reads "RoCE v2" is the index.
resolve_gid_index() {
  local dev="${HCA_ONE%%,*}" port types t
  for port in /sys/class/infiniband/"$dev"/ports/*; do
    types="$port/gid_attrs/types"
    [ -d "$types" ] || continue
    for t in "$types"/*; do
      [ -f "$t" ] || continue
      if grep -qi 'RoCE v2' "$t" 2>/dev/null; then basename "$t"; return; fi
    done
  done
  echo ""
}
GID_INDEX="$GID_CFG"
if [ -z "$GID_INDEX" ] || [ "$GID_INDEX" = auto ]; then GID_INDEX="$(resolve_gid_index)"; fi

# make sure the local launcher can ssh to the peer (peer must run sshd too)
pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null || true

TS="$(date +%Y%m%d-%H%M%S)"
RUNDIR="$RESULTS/${LABEL}-${TS}"; mkdir -p "$RUNDIR/nccl"

run_nccl(){ # hca outfile
  local hca="$1" out="$2"
  # shellcheck disable=SC2086
  mpirun --allow-run-as-root -np 2 -H "$(hostname),$PEER" \
    --mca plm_rsh_args "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes" \
    -x NCCL_IB_HCA="$hca" \
    -x NCCL_DEBUG="$DEBUG" \
    -x NCCL_IB_DISABLE="$IB_DISABLE" \
    -x NCCL_SOCKET_IFNAME="$SOCK_IFNAME" \
    ${GID_INDEX:+-x NCCL_IB_GID_INDEX="$GID_INDEX"} \
    -x LD_LIBRARY_PATH -x PATH \
    "$COLLECTIVE" -b "$BEGIN" -e "$END" -f "$FACTOR" -g "$GPUS" 2>&1 | tee "$out"
}

busbw(){ awk '/Avg bus bandwidth/ {v=$(NF)} END{print (v==""?"NA":v)}' "$1"; }

echo "NCCL $COLLECTIVE  peer=$PEER  gpus/proc=$GPUS"
echo "  one=$HCA_ONE  all=$HCA_ALL  gid_index=${GID_INDEX:-<none>}  sock=$SOCK_IFNAME  -> $RUNDIR"
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
  "collective": "$COLLECTIVE",
  "gpus_per_proc": $GPUS,
  "gid_index": "${GID_INDEX:-NA}"
}
EOF

cat > "$RUNDIR/nccl/nccl.json" <<EOF
{"collective":"$COLLECTIVE","one":{"hca":"$HCA_ONE","busbw":$( [ "$ONE" = NA ] && echo 0 || echo "$ONE")},"all":{"hca":"$HCA_ALL","busbw":$( [ "$ALL" = NA ] && echo 0 || echo "$ALL")}}
EOF

echo "DONE  one=$ONE GB/s  all=$ALL GB/s  -> $RUNDIR/nccl/nccl.json"
