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
OUT_DIR="./report"

SERVER_POD="rdma-server"
SCRIPT_PATH="/opt/roce/roce_bench.sh"
PLOT_PATH="/opt/roce/plot_report.py"
RESULTS_DIR="/results"

# client pod  ->  env-label (tags the run directory)
CLIENTS=(
  "rdma-client-leaf:same-leaf"
  "rdma-client-spine:spine-crossing"
)

usage() {
  echo "usage: $0 -n <namespace> [--report] [--out <dir>]"
  echo "  -n, --namespace   OpenShift namespace the chart is installed in (required)"
  echo "      --report      generate report.html and copy it to <dir> (default: ./report)"
  echo "      --out         output directory for --report (default: ./report)"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
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
# 4. Optional: generate the report inside a pod and copy it back locally.
# ----------------------------------------------------------------------------
if [ "$MAKE_REPORT" = true ]; then
  log "Generating report on $SERVER_POD..."
  oc_exec "$SERVER_POD" "python3 $PLOT_PATH $RESULTS_DIR report"
  # kubectl/oc cp creates OUT_DIR from the source dir's contents (parent must exist).
  mkdir -p "$(dirname "$OUT_DIR")"
  log "Copying report to $OUT_DIR ..."
  oc cp -n "$NAMESPACE" "$SERVER_POD:$RESULTS_DIR/report" "$OUT_DIR"
  echo "Report at: $OUT_DIR/report.html"
fi

log "Done."
