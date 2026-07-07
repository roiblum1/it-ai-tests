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
SHM_DISABLE="${NCCL_SHM_DISABLE_CFG:-0}"   # "1" = skip the SHM transport (escape hatch)

NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-/opt/nccl-tests}"

# Multi-rail pods need per-rail source routing before any cross-node traffic
# (see rail_routes.sh: one table + source rule per VF, loose rp_filter).
# Idempotent, and `build` runs on BOTH pods -- so both are routed before mpirun.
RAIL_ROUTES="${RAIL_ROUTES:-/opt/roce/rail_routes.sh}"
[ -f "$RAIL_ROUTES" ] && bash "$RAIL_ROUTES" >/dev/null 2>&1 || true

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

# HCA list -- derive from THIS POD's rail netdevs (the interfaces that hold an
# IPv4), NOT a bare /sys/class/infiniband listing: a privileged pod can see RDMA
# devices that are not its rails (host PFs / other VFs), and an IP-less device
# has no IPv4-mapped GID -- NCCL's ibv_modify_qp on those fails with errno 19
# (No such device). Each rail netdev maps to its RDMA device via sysfs.
detect_hcas() {
  local ifc dev
  for ifc in $(ip -br -4 addr show 2>/dev/null \
                 | awk '{sub(/@.*/, "", $1)} $1!="lo" && $1!~/^eth0/ {print $1}'); do
    dev="$(ls /sys/class/net/"$ifc"/device/infiniband 2>/dev/null | head -n1)"
    [ -n "$dev" ] && echo "$dev"
  done | awk '!seen[$0]++' | paste -sd, -
}
HCA_ALL="${NCCL_HCA_ALL:-auto}"; HCA_ONE="${NCCL_HCA_ONE:-auto}"
if [ -z "$HCA_ALL" ] || [ "$HCA_ALL" = auto ]; then HCA_ALL="$(detect_hcas)"; fi
if [ -z "$HCA_ONE" ] || [ "$HCA_ONE" = auto ]; then HCA_ONE="${HCA_ALL%%,*}"; fi
[ -z "$HCA_ALL" ] && { echo "no RDMA devices found under /sys/class/infiniband"; exit 1; }

# Resolve the RoCEv2 GID index of the first rail from sysfs (no show_gids/MOFED
# dependency). On a ROUTED fabric we need the IPv4-mapped "RoCE v2" GID
# (::ffff:<rail-ip>, typically index 3): the link-local fe80:: v2 GID (usually
# index 1) is NOT routable across the /31 leaf gateways, and picking it makes
# every cross-node QP fail. Fall back to the first v2 entry if no IPv4-mapped
# one exists (e.g. the rail has no IP yet).
resolve_gid_index() {
  local dev="${HCA_ONE%%,*}" port types t idx fallback=""
  for port in /sys/class/infiniband/"$dev"/ports/*; do
    types="$port/gid_attrs/types"
    [ -d "$types" ] || continue
    for t in "$types"/*; do
      [ -f "$t" ] || continue
      grep -qi 'RoCE v2' "$t" 2>/dev/null || continue
      idx="$(basename "$t")"
      if grep -q '0000:0000:0000:0000:0000:ffff:' "$port/gids/$idx" 2>/dev/null; then
        echo "$idx"; return           # IPv4-mapped v2 GID -- the routable one
      fi
      [ -z "$fallback" ] && fallback="$idx"
    done
  done
  echo "$fallback"
}
GID_INDEX="$GID_CFG"
if [ -z "$GID_INDEX" ] || [ "$GID_INDEX" = auto ]; then GID_INDEX="$(resolve_gid_index)"; fi

# make sure the local launcher can ssh to the peer (peer must run sshd too)
pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null || true

TS="$(date +%Y%m%d-%H%M%S)"
RUNDIR="$RESULTS/${LABEL}-${TS}"; mkdir -p "$RUNDIR/nccl"

# Number of message sizes the collective will sweep (BEGIN * FACTOR^k <= END), so
# the progress line can show "k/N". Sizes accept K/M/G suffixes.
to_bytes(){ echo "$1" | awk 'BEGIN{IGNORECASE=1}
  { n=$0; u=1
    if (n ~ /[Kk]$/) {u=1024;      sub(/[Kk]$/,"",n)}
    else if (n ~ /[Mm]$/) {u=1048576;   sub(/[Mm]$/,"",n)}
    else if (n ~ /[Gg]$/) {u=1073741824;sub(/[Gg]$/,"",n)}
    printf "%d", n*u }'; }
NSIZES="$(awk -v b="$(to_bytes "$BEGIN")" -v e="$(to_bytes "$END")" -v f="$FACTOR" \
  'BEGIN{ n=0; for (s=b; s<=e; s*=f) n++; print (n>0?n:1) }')"

# sshd-spawned ranks do NOT inherit the image's baked-in ENV, so a remote rank can
# die with "error while loading shared libraries: libcudart.so.12" (or libnccl.so.2)
# even though the launcher is fine. Resolve the real dirs of those libs and forward
# an EXPLICIT LD_LIBRARY_PATH to every rank -- belt-and-suspenders over -x
# LD_LIBRARY_PATH, and covering both CUDA layouts (lib64 and targets/<arch>/lib).
resolve_lib_dirs() {
  local dirs="" lib p d
  for lib in libcudart.so libnccl.so; do
    for p in $(ldconfig -p 2>/dev/null | awk -v n="$lib" 'index($1,n){print $NF}'); do
      dirs="$dirs:$(dirname "$p")"
    done
  done
  for d in /usr/local/cuda/lib64 /usr/local/cuda/targets/*/lib /usr/lib/x86_64-linux-gnu; do
    [ -d "$d" ] && dirs="$dirs:$d"
  done
  echo "${dirs#:}" | tr ':' '\n' | awk 'NF && !seen[$0]++' | paste -sd: -
}
MPI_LD_LIBRARY_PATH="$(resolve_lib_dirs):${LD_LIBRARY_PATH:-}"
BIN="$NCCL_TESTS_DIR/build/$COLLECTIVE"   # absolute -- remote ranks may lack it on PATH

# mpirun is only the bootstrap here (ssh-launch + a small OOB/BTL handshake); NCCL
# itself moves the data over the RoCE HCAs. The pods are multi-homed (eth0 pod-SDN
# + 8 RoCE rails), so left to itself OpenMPI may advertise an unroutable rail IP
# and the peer's "connect ... :1024" times out (EINPROGRESS). Pin every MPI TCP
# channel to the pod-SDN iface and force the plain ob1/tcp stack so MPI never
# probes the rails.
run_nccl(){ # hca outfile tag
  local hca="$1" out="$2" tag="$3"
  echo ">>> NCCL $tag : NCCL_IB_HCA=$hca  ($COLLECTIVE $BEGIN..$END, $NSIZES sizes) -- this can take a while"
  # shellcheck disable=SC2086
  mpirun --allow-run-as-root -np 2 -H "$(hostname),$PEER" \
    --mca plm_rsh_args "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes" \
    --mca pml ob1 --mca btl self,tcp \
    --mca btl_tcp_if_include "$SOCK_IFNAME" \
    --mca oob_tcp_if_include "$SOCK_IFNAME" \
    -x NCCL_IB_HCA="$hca" \
    -x NCCL_DEBUG="$DEBUG" \
    -x NCCL_IB_DISABLE="$IB_DISABLE" \
    -x NCCL_SHM_DISABLE="$SHM_DISABLE" \
    -x NCCL_SOCKET_IFNAME="$SOCK_IFNAME" \
    ${GID_INDEX:+-x NCCL_IB_GID_INDEX="$GID_INDEX"} \
    -x LD_LIBRARY_PATH="$MPI_LD_LIBRARY_PATH" -x PATH \
    "$BIN" -b "$BEGIN" -e "$END" -f "$FACTOR" -g "$GPUS" 2>&1 \
    | tee "$out" \
    | awk -v total="$NSIZES" -v tag="$tag" '
        # echo NCCL/MPI diagnostics through; add a compact per-size progress line.
        /^[[:space:]]*#/ { print; next }
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
          done++; printf "    NCCL %s progress: %d/%d  (size=%s bytes)\n", tag, done, total, $1; next }
        { print }'
}

busbw(){ awk '/Avg bus bandwidth/ {v=$(NF)} END{print (v==""?"NA":v)}' "$1"; }

echo "NCCL $COLLECTIVE  peer=$PEER  gpus/proc=$GPUS"
echo "  one=$HCA_ONE  all=$HCA_ALL  gid_index=${GID_INDEX:-<none>}  sock=$SOCK_IFNAME  -> $RUNDIR"
run_nccl "$HCA_ONE" "$RUNDIR/nccl/one_hca.txt" "[1/2] one-HCA"
run_nccl "$HCA_ALL" "$RUNDIR/nccl/all_hca.txt" "[2/2] all-HCA"
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
