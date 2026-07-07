#!/usr/bin/env bash
# ============================================================================
# run_suite.sh -- drive the 1-to-1 RoCE benchmark from your laptop with `oc`.
#
# This is the "drive only" orchestrator: it assumes the roce-perf chart is
# ALREADY installed (helm install ...). It then:
#   1. waits for the three pods to be Ready,
#   2. discovers the server's RoCE IP automatically (ip -br a inside the pod),
#   3. runs the benchmark from each client (same-leaf, then spine-crossing),
#   4. (optional) generates the report and copies report.html back locally.
#
#   ./run_suite.sh -n <namespace> [--report] [--out <dir>]
#
# Pod names are fixed by the chart: rdma-server, rdma-client-leaf,
# rdma-client-spine. The server's listeners come up on their own (autostart),
# so the clients just need the server IP.
# ============================================================================
set -euo pipefail

NAMESPACE=""
MAKE_REPORT=false
RUN_NCCL=false
OUT_DIR="./report"

SERVER_POD="rdma-server"
SCRIPT_PATH="/opt/roce/roce_bench.sh"
NCCL_SCRIPT="/opt/roce/nccl_one_vs_many.sh"
RAIL_ROUTES="/opt/roce/rail_routes.sh"
PLOT_PATH="/opt/roce/plot_report.py"
RESULTS_DIR="/results"
REPORT_SUBDIR="report"

NCCL_LAUNCHER="nccl-launcher"
NCCL_PEER="nccl-peer"

# client pod  ->  env-label (tags the run directory)
CLIENTS=(
  "rdma-client-leaf:same-leaf"
  "rdma-client-spine:spine-crossing"
)

usage() {
  echo "usage: $0 -n <namespace> [--nccl] [--report] [--out <dir>]"
  echo "  -n, --namespace   OpenShift namespace the chart is installed in (required)"
  echo "      --nccl        also run the NCCL one-vs-many test (needs nccl.enabled=true)"
  echo "      --report      generate report.html and copy it to <dir> (default: ./report)"
  echo "      --out         output directory for --report (default: ./report)"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --nccl)         RUN_NCCL=true;      shift ;;
    --report)       MAKE_REPORT=true;   shift ;;
    --out)          OUT_DIR="${2:-}";   shift 2 ;;
    -h|--help)      usage ;;
    *) echo "unknown argument: $1"; usage ;;
  esac
done
[ -z "$NAMESPACE" ] && usage

oc_exec() { oc exec -n "$NAMESPACE" "$1" -- bash -c "$2"; }

log() { echo -e "\n>>> $*"; }

# ----------------------------------------------------------------------------
# 0. Grant the privileged SCC to the pods' service account (idempotent). The pods
#    run privileged; SCC is checked at pod ADMISSION, so this is best applied
#    BEFORE the chart is installed. If the pods are already stuck on admission,
#    re-run helm install/upgrade after this grant.
# ----------------------------------------------------------------------------
log "Granting privileged SCC to the 'default' service account in $NAMESPACE (idempotent)..."
oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE" \
  || echo "WARN: could not grant privileged SCC (need cluster-admin?); the pods must already be allowed to run privileged"

# ----------------------------------------------------------------------------
# 1. Wait for all pods to be Ready.
# ----------------------------------------------------------------------------
log "Waiting for pods to be Ready in namespace '$NAMESPACE'..."
for pod in "$SERVER_POD" "${CLIENTS[@]%%:*}"; do
  oc wait -n "$NAMESPACE" --for=condition=Ready "pod/$pod" --timeout=180s
done

# ----------------------------------------------------------------------------
# 2. Discover the server's RoCE IP.
#    Inside the pod, `ip -br a` lists the interfaces; we skip loopback and the
#    default cluster network (eth0) and take the Multus VF netdev (e.g. net1).
# ----------------------------------------------------------------------------
log "Discovering server RoCE IP from $SERVER_POD..."
SERVER_IP="$(oc_exec "$SERVER_POD" \
  "ip -br -4 addr show | awk '\$1!=\"lo\" && \$1!~/^eth0/ {split(\$3,a,\"/\"); print a[1]; exit}'")"
SERVER_IP="$(echo "$SERVER_IP" | tr -d '[:space:]')"

if [ -z "$SERVER_IP" ]; then
  echo "ERROR: could not determine the server RoCE IP. Interfaces seen:"
  oc_exec "$SERVER_POD" "ip -br -4 addr show"
  exit 1
fi
echo "Server RoCE IP: $SERVER_IP"

# ----------------------------------------------------------------------------
# 3. Run the benchmark from each client against that IP. The client auto-detects
#    its own RDMA device (passing "auto").
# ----------------------------------------------------------------------------
for entry in "${CLIENTS[@]}"; do
  pod="${entry%%:*}"
  label="${entry##*:}"
  log "Running benchmark from $pod (env=$label)..."
  oc_exec "$pod" "bash $SCRIPT_PATH client auto $SERVER_IP $label"
done

# ----------------------------------------------------------------------------
# 3b. Optional NCCL one-vs-many. Set up passwordless SSH between the two NCCL
#     pods, build nccl-tests on both, then launch mpirun from the launcher.
# ----------------------------------------------------------------------------
if [ "$RUN_NCCL" = true ]; then
  # The 8-GPU/8-rail NCCL pods can't schedule while the perftest pods hold GPUs and
  # rail VFs -- they stay Pending. Free those resources now by deleting the perftest
  # pods. Their run dirs live on the node's hostPath (results.hostPath, the default)
  # and survive the pod deletion; the NCCL pods land on the same nodes and re-mount
  # that same hostPath, so --report can still gather them below. (This needs a
  # non-emptyDir backend: hostPath (default) or a shared PVC.)
  log "NCCL: deleting perftest pods to free GPUs/rails ($SERVER_POD + clients; results persist on hostPath)..."
  oc delete pod -n "$NAMESPACE" "$SERVER_POD" "${CLIENTS[@]%%:*}" \
    --ignore-not-found --wait=true --timeout=120s || true

  log "NCCL: waiting for $NCCL_LAUNCHER and $NCCL_PEER (needs nccl.enabled=true)..."
  for p in "$NCCL_LAUNCHER" "$NCCL_PEER"; do
    oc wait -n "$NAMESPACE" --for=condition=Ready "pod/$p" --timeout=300s
  done

  # Multi-rail pods hold 8 VFs whose routes all point at the same fabric /24;
  # without source routing, rail N's traffic may egress rail M's gateway (and
  # ping between VF IPs fails). rail_routes.sh gives every rail its own table.
  log "NCCL: applying per-rail source routing on both pods..."
  for p in "$NCCL_LAUNCHER" "$NCCL_PEER"; do
    oc_exec "$p" "bash $RAIL_ROUTES"
  done

  # Same-rail reachability check, launcher -> peer, one ping per rail. Multus
  # names the rails identically on both pods (net1..netN, annotation order), so
  # matching by interface name pairs rail i with rail i. Warn-only.
  log "NCCL: same-rail ping check ($NCCL_LAUNCHER -> $NCCL_PEER)..."
  PEER_RAILS="$(oc_exec "$NCCL_PEER" \
    "ip -br -4 addr show | awk '{sub(/@.*/, \"\", \$1)} \$1!=\"lo\" && \$1!~/^eth0/ {split(\$3,a,\"/\"); print \$1, a[1]}'")"
  while read -r ifc peer_ip; do
    [ -z "$ifc" ] && continue
    local_ip="$(oc_exec "$NCCL_LAUNCHER" \
      "ip -br -4 addr show dev $ifc 2>/dev/null | awk '{split(\$3,a,\"/\"); print a[1]; exit}'" | tr -d '[:space:]')"
    [ -z "$local_ip" ] && { echo "  $ifc: no matching rail on the launcher, skipping"; continue; }
    if oc_exec "$NCCL_LAUNCHER" "ping -c1 -W2 -I $local_ip $peer_ip >/dev/null 2>&1"; then
      echo "  $ifc: $local_ip -> $peer_ip  OK"
    else
      echo "  WARN: $ifc: $local_ip -> $peer_ip  FAILED (rail down, or the fabric does not route this pair)"
    fi
  done <<< "$PEER_RAILS"

  log "NCCL: setting up passwordless SSH between the pods..."
  for p in "$NCCL_LAUNCHER" "$NCCL_PEER"; do
    oc_exec "$p" 'pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd'
  done
  oc_exec "$NCCL_LAUNCHER" 'test -f ~/.ssh/id_rsa || { mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t rsa -N "" -f ~/.ssh/id_rsa; }'
  PUBKEY="$(oc_exec "$NCCL_LAUNCHER" 'cat ~/.ssh/id_rsa.pub')"
  for p in "$NCCL_LAUNCHER" "$NCCL_PEER"; do
    printf '%s\n' "$PUBKEY" | oc exec -i -n "$NAMESPACE" "$p" -- bash -c \
      'mkdir -p ~/.ssh && chmod 700 ~/.ssh && k=$(cat); grep -qxF "$k" ~/.ssh/authorized_keys 2>/dev/null || echo "$k" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'
  done

  log "NCCL: building nccl-tests on both pods (first run only)..."
  for p in "$NCCL_LAUNCHER" "$NCCL_PEER"; do
    oc_exec "$p" "bash $NCCL_SCRIPT build"
  done

  PEER_IP="$(oc get pod -n "$NAMESPACE" "$NCCL_PEER" -o jsonpath='{.status.podIP}')"
  [ -z "$PEER_IP" ] && { echo "ERROR: could not read $NCCL_PEER pod IP"; exit 1; }
  log "NCCL: launching from $NCCL_LAUNCHER against peer $PEER_IP..."
  oc_exec "$NCCL_LAUNCHER" "bash $NCCL_SCRIPT $PEER_IP nccl"
fi

# ----------------------------------------------------------------------------
# Pick the report pod (where we gather + plot) and which pods to pull results
# FROM. With --nccl the perftest pods are gone, but their hostPath run dirs are
# still on the nodes; the two NCCL pods sit on those same nodes, so the launcher
# already sees its node's run dirs and only needs the peer's pulled in. Without
# --nccl, keep the original flow: gather the clients into the server.
# ----------------------------------------------------------------------------
if [ "$RUN_NCCL" = true ]; then
  REPORT_POD="$NCCL_LAUNCHER"
  GATHER_PODS=( "$NCCL_PEER" )
else
  REPORT_POD="$SERVER_POD"
  GATHER_PODS=( "${CLIENTS[@]%%:*}" )
fi

# ----------------------------------------------------------------------------
# 4. Optional: build the combined report and copy it back locally.
#
# Each pod's results live in node-local storage (hostPath/emptyDir), and the
# clients are on different nodes than the server, so we first GATHER every
# client's run dirs into the server pod (stream a tar over `oc exec`), then run
# the plotter there. With a shared PVC this gather is just a harmless no-op.
# ----------------------------------------------------------------------------
if [ "$MAKE_REPORT" = true ]; then
  for pod in "${GATHER_PODS[@]}"; do
    log "Gathering results from $pod -> $REPORT_POD ..."
    oc exec -n "$NAMESPACE" "$pod" -- \
      tar -C "$RESULTS_DIR" --exclude="./$REPORT_SUBDIR" -cf - . \
      | oc exec -i -n "$NAMESPACE" "$REPORT_POD" -- tar -C "$RESULTS_DIR" -xf -
  done

  runs=$(oc_exec "$REPORT_POD" "ls $RESULTS_DIR/*/setup.json 2>/dev/null | wc -l" | tr -d '[:space:]')
  if [ "${runs:-0}" -eq 0 ]; then
    echo "ERROR: no run directories found after gathering. Did the clients run?"
    exit 1
  fi

  log "Generating report on $REPORT_POD..."
  oc_exec "$REPORT_POD" "python3 $PLOT_PATH $RESULTS_DIR $REPORT_SUBDIR"
  # kubectl/oc cp creates OUT_DIR from the source dir's contents (parent must exist).
  mkdir -p "$(dirname "$OUT_DIR")"
  log "Copying report to $OUT_DIR ..."
  oc cp -n "$NAMESPACE" "$REPORT_POD:$RESULTS_DIR/$REPORT_SUBDIR" "$OUT_DIR"
  echo "Report at: $OUT_DIR/report.html"
fi

log "Done."
