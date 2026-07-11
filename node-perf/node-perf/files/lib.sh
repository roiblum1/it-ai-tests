#!/usr/bin/env bash
# ============================================================================
# lib.sh -- shared helpers for the node-perf benchmark modules.
#
# Sourced by node_bench.sh and every bench_<x>.sh. Provides:
#   make_run_dir <label>            -> echoes a fresh /results/<label>-<ts> dir
#   collect_setup <run_dir> <label> <note>   -> writes <run_dir>/setup.json
#   metric_begin                    -> start a metrics accumulator for a module
#   metric_add <name> <dim> <unit> <value> <hib>   -> append one metric record
#   metric_flush <group> <benchmark> <outfile>     -> write <group>/metrics.json
#
# The metrics.json a module emits is the ONLY contract report.py reads, so a new
# benchmark is just a new bench_<x>.sh that emits one -- no report changes.
# ============================================================================

RESULTS="${RESULTS:-/results}"

make_run_dir() { # label -> path
  local label="$1"
  local rd="$RESULTS/${label}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$rd"
  echo "$rd"
}

collect_setup() { # run_dir label note
  local rd="$1" label="$2" note="$3"
  # Gather tuning-relevant node context so the report documents WHAT changed
  # between baseline and tuned. Everything is best-effort (NA if unavailable).
  NP_NODE="${NODE_NAME:-$(hostname)}" \
  NP_KERNEL="$(uname -r 2>/dev/null || echo NA)" \
  NP_CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')" \
  NP_CPU_CORES="$(nproc 2>/dev/null || echo NA)" \
  NP_MEM_TOTAL="$(awk '/MemTotal/{printf "%.1f GiB", $2/1048576; exit}' /proc/meminfo 2>/dev/null || echo NA)" \
  NP_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)" \
  NP_HUGEPAGES="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo NA)" \
  NP_THP="$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo NA)" \
  NP_TUNED="$(tuned-adm active 2>/dev/null | sed 's/^[^:]*: //' || echo NA)" \
  NP_NUMA="$(lscpu 2>/dev/null | awk -F: '/^NUMA node\(s\)/{gsub(/^[ \t]+/,"",$2); print $2; exit}')" \
  NP_LABEL="$label" NP_NOTE="$note" NP_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  python3 - "$rd/setup.json" <<'PY'
import json, os, sys
fields = [
    ("node",       "NP_NODE"),
    ("kernel",     "NP_KERNEL"),
    ("cpu_model",  "NP_CPU_MODEL"),
    ("cpu_cores",  "NP_CPU_CORES"),
    ("mem_total",  "NP_MEM_TOTAL"),
    ("governor",   "NP_GOVERNOR"),
    ("hugepages",  "NP_HUGEPAGES"),
    ("thp",        "NP_THP"),
    ("tuned",      "NP_TUNED"),
    ("numa_nodes", "NP_NUMA"),
    ("label",      "NP_LABEL"),
    ("note",       "NP_NOTE"),
    ("date",       "NP_DATE"),
]
d = {k: (os.environ.get(e, "") or "NA") for k, e in fields}
d["env_label"] = d["label"]      # what report.py's discover_runs keys on
with open(sys.argv[1], "w") as fh:
    json.dump(d, fh, indent=2)
PY
}

# ---- metrics accumulator ---------------------------------------------------
# A module calls metric_begin, then metric_add per number, then metric_flush.

metric_begin() {
  METRIC_ACC="$(mktemp)"
}

_num_or_null() { # value -> a JSON number, or null if not numeric
  case "$1" in
    ''|*[!0-9.eE+-]*) echo null ;;
    *) [ -n "$1" ] && echo "$1" || echo null ;;
  esac
}

metric_add() { # name dim unit value higher_is_better(true|false)
  local name="$1" dim="$2" unit="$3" value="$4" hib="$5"
  printf '{"name":"%s","dim":"%s","unit":"%s","value":%s,"higher_is_better":%s}\n' \
    "$name" "$dim" "$unit" "$(_num_or_null "$value")" "$hib" >> "$METRIC_ACC"
}

metric_flush() { # group benchmark outfile
  local group="$1" bench="$2" out="$3"
  local body=""
  [ -s "$METRIC_ACC" ] && body="$(paste -sd, "$METRIC_ACC")"
  printf '{"group":"%s","benchmark":"%s","metrics":[%s]}\n' "$group" "$bench" "$body" > "$out"
  rm -f "$METRIC_ACC"
  echo "  wrote $out ($(grep -o '"name"' "$out" | wc -l | tr -d ' ') metrics)"
}
