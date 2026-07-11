#!/usr/bin/env bash
# ============================================================================
# node_bench.sh -- in-pod orchestrator for the node-perf benchmarks.
#
#   node_bench.sh run <label> [note]
#
# Builds a run dir + setup.json, then runs every bench_<x>.sh module found next
# to it (each self-gates on its own <X>_ENABLED env). Adding a benchmark = drop
# a bench_<x>.sh here + wire its env in the chart; this file needs no change.
#
# The comparison axis is the LABEL: run once as "baseline", make a tuning
# change, run again as "tuned" -- report.py compares them.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() {
  echo "usage: $0 run <label> [note]"
  echo "  run     execute the enabled benchmark modules"
  echo "  label   tags the run dir (baseline vs tuned vs ...); MUST differ between runs you compare"
  echo "  note    free-text describing this run's config (e.g. 'governor=performance')"
  exit 1
}

cmd="${1:-}"
case "$cmd" in
  run) : ;;
  *) usage ;;
esac
label="${2:-}"
note="${3:-}"
[ -z "$label" ] && usage

run_dir="$(make_run_dir "$label")"
# Everything from here (each module's stdout) is also captured to full.log.
exec > >(tee "$run_dir/full.log") 2>&1

echo ">>> node-perf run: label=$label note='${note:-}' node=${NODE_NAME:-$(hostname)}"
echo ">>> run dir: $run_dir"
collect_setup "$run_dir" "$label" "$note"
echo ">>> setup:"
cat "$run_dir/setup.json"
echo

rc=0
for mod in "$DIR"/bench_*.sh; do
  [ -e "$mod" ] || continue
  name="$(basename "$mod")"
  echo ">>> module: $name"
  if bash "$mod" "$run_dir"; then
    echo ">>> $name done"
  else
    echo "WARN: $name exited non-zero (continuing)"
    rc=1
  fi
  echo
done

echo ">>> node-perf run complete: $run_dir"
exit $rc
