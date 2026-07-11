#!/usr/bin/env bash
# ============================================================================
# run_suite.sh -- top-level dispatcher for the benchmark subjects.
#
# Each subject has its OWN driver (the flows differ: RoCE does IP discovery +
# NCCL/rail-routing; node-perf does label-based baseline-vs-tuned runs). This is
# the one shared entry point at the repo root -- it just forwards to the chosen
# subject's driver with all remaining args.
#
#   ./run_suite.sh <subject> [args...]
#     roce        -> RoCE-tests-chart/run_suite.sh   (RDMA BW/latency, GPUDirect, NCCL)
#     node-perf   -> node-perf/run_suite.sh          (CPU/memory/disk tuning)
#
# Examples:
#   ./run_suite.sh node-perf -n bench --label baseline --report
#   ./run_suite.sh roce      -n bench --nccl --report
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
usage: $0 <subject> [args...]

  subjects:
    roce        RoCE leaf/spine RDMA benchmark  -> RoCE-tests-chart/run_suite.sh
    node-perf   node CPU/memory/disk tuning     -> node-perf/run_suite.sh

  all args after <subject> pass through to that subject's driver, e.g.:
    $0 node-perf -n bench --label baseline --report
    $0 roce      -n bench --nccl --report

  (you can still call a subject's driver directly, e.g. ./node-perf/run_suite.sh ...)
EOF
  exit 1
}

[ $# -lt 1 ] && usage
subject="$1"; shift || true
case "$subject" in
  roce|RoCE|roce-tests|RoCE-tests-chart) driver="$ROOT/RoCE-tests-chart/run_suite.sh" ;;
  node-perf|node|nodeperf)               driver="$ROOT/node-perf/run_suite.sh" ;;
  -h|--help)                             usage ;;
  *) echo "unknown subject: $subject" >&2; usage ;;
esac

[ -f "$driver" ] || { echo "driver not found: $driver" >&2; exit 1; }
exec bash "$driver" "$@"
