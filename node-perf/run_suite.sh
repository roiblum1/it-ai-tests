#!/usr/bin/env bash
# ============================================================================
# run_suite.sh -- drive the node-perf benchmarks from your laptop with `oc`.
#
# Assumes the node-perf chart is ALREADY installed (helm install ...). It then:
#   1. finds + waits for the benchmark pods (one per node),
#   2. runs node_bench.sh in each under a chosen --label,
#   3. (optional) gathers every pod's run dirs into one pod, builds the report,
#      and copies report.html back locally.
#
#   ./run_suite.sh -n <ns> [--label <name>] [--note "<text>"] \
#                  [--baseline <label>] [--report] [--out <dir>]
#
# The comparison axis is the LABEL: run once as "baseline", make a tuning
# change, run again as "tuned" -- the report compares them with a per-metric
# delta. baseline and tuned MUST use different labels.
# ============================================================================
set -euo pipefail

NAMESPACE=""
LABEL="baseline"
NOTE=""
BASELINE="baseline"
MAKE_REPORT=false
OUT_DIR="./report"

SELECTOR="app.kubernetes.io/name=node-perf"
SCRIPT_PATH="/opt/node-perf/node_bench.sh"
REPORT_PATH="/opt/node-perf/report.py"
RESULTS_DIR="/results"
REPORT_SUBDIR="report"

usage() {
  echo "usage: $0 -n <namespace> [--label <name>] [--note \"<text>\"] [--baseline <label>] [--report] [--out <dir>]"
  echo "  -n, --namespace   namespace the chart is installed in (required)"
  echo "      --label       run label; tags the run dir (default: baseline). Use a"
  echo "                    DIFFERENT label for each config you compare (baseline/tuned)"
  echo "      --note        free-text describing this run's config (e.g. 'governor=performance')"
  echo "      --baseline    which label deltas are computed against in the report (default: baseline)"
  echo "      --report      gather results, build report.html, copy it to --out"
  echo "      --out         output directory for --report (default: ./report)"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --label)        LABEL="${2:-}";     shift 2 ;;
    --note)         NOTE="${2:-}";      shift 2 ;;
    --baseline)     BASELINE="${2:-}";  shift 2 ;;
    --report)       MAKE_REPORT=true;   shift ;;
    --out)          OUT_DIR="${2:-}";   shift 2 ;;
    -h|--help)      usage ;;
    *) echo "unknown argument: $1"; usage ;;
  esac
done
[ -z "$NAMESPACE" ] && usage
[ -z "$LABEL" ] && { echo "ERROR: --label must not be empty"; exit 1; }

oc_exec() { oc exec -n "$NAMESPACE" "$1" -- bash -c "$2"; }
log() { echo -e "\n>>> $*"; }

# ----------------------------------------------------------------------------
# 0. Grant privileged SCC (idempotent); the pods run privileged so fio can open
#    the node device with O_DIRECT. Applied best-effort.
# ----------------------------------------------------------------------------
log "Granting privileged SCC to 'default' SA in $NAMESPACE (idempotent)..."
oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE" \
  || echo "WARN: could not grant privileged SCC (need cluster-admin?); pods must already be allowed"

# ----------------------------------------------------------------------------
# 1. Find the benchmark pods (one per node) and wait for them.
# ----------------------------------------------------------------------------
log "Finding node-perf pods in '$NAMESPACE'..."
read -r -a PODS <<< "$(oc get pods -n "$NAMESPACE" -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name} {end}')"
if [ "${#PODS[@]}" -eq 0 ]; then
  echo "ERROR: no pods match -l $SELECTOR in $NAMESPACE. Is the chart installed?"
  exit 1
fi
echo "Pods: ${PODS[*]}"
for pod in "${PODS[@]}"; do
  oc wait -n "$NAMESPACE" --for=condition=Ready "pod/$pod" --timeout=180s
done

# ----------------------------------------------------------------------------
# 2. Run the benchmarks in each pod under this label.
# ----------------------------------------------------------------------------
for pod in "${PODS[@]}"; do
  log "Running benchmarks in $pod (label=$LABEL)..."
  oc_exec "$pod" "bash $SCRIPT_PATH run $(printf %q "$LABEL") $(printf %q "$NOTE")"
done

# ----------------------------------------------------------------------------
# 3. Optional: gather every pod's node-local run dirs into the first pod, build
#    the report there, and copy it back. (A shared PVC makes the gather a no-op.)
# ----------------------------------------------------------------------------
if [ "$MAKE_REPORT" = true ]; then
  REPORT_POD="${PODS[0]}"
  for pod in "${PODS[@]:1}"; do
    log "Gathering results from $pod -> $REPORT_POD ..."
    oc exec -n "$NAMESPACE" "$pod" -- \
      tar -C "$RESULTS_DIR" --exclude="./$REPORT_SUBDIR" -cf - . \
      | oc exec -i -n "$NAMESPACE" "$REPORT_POD" -- tar -C "$RESULTS_DIR" -xf -
  done

  runs=$(oc_exec "$REPORT_POD" "ls $RESULTS_DIR/*/setup.json 2>/dev/null | wc -l" | tr -d '[:space:]')
  if [ "${runs:-0}" -eq 0 ]; then
    echo "ERROR: no run directories found after gathering. Did the benchmarks run?"
    exit 1
  fi

  log "Generating report on $REPORT_POD (baseline=$BASELINE)..."
  oc_exec "$REPORT_POD" "REPORT_BASELINE=$(printf %q "$BASELINE") python3 $REPORT_PATH $RESULTS_DIR $REPORT_SUBDIR"
  mkdir -p "$(dirname "$OUT_DIR")"
  log "Copying report to $OUT_DIR ..."
  oc cp -n "$NAMESPACE" "$REPORT_POD:$RESULTS_DIR/$REPORT_SUBDIR" "$OUT_DIR"
  echo "Report at: $OUT_DIR/report.html"
fi

log "Done."
