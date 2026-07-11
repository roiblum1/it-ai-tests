# CLAUDE.md — node performance-tuning benchmark

This file guides Claude Code (claude.ai/code) when working in this subject. It is
the **node-perf subject** of a multi-subject benchmark repo — see the repo-level
[README](../README.md) for the collection and this folder's [README](README.md) for
the user-facing quickstart. This file is the architecture / contributor guide.

## What this is

A Helm chart, `node-perf` (at [node-perf/](node-perf/)), that deploys **idle
benchmark pods** (one per node) onto OpenShift, a host-side `oc` driver, in-pod
benchmark **modules**, and a **generic, metric-driven** report generator.

It measures a node's **CPU (sysbench), memory (sysbench), and disk (fio)**
performance, and its whole point is the **baseline-vs-tuned comparison**: run once,
change a tuning knob, run again, and read the per-metric **Δ%**. The comparison axis
is the **run label** (`baseline` vs `tuned`), not a topology — this mirrors how the
[RoCE subject](../RoCE-tests-chart/CLAUDE.md) compares `same-leaf` vs
`spine-crossing`, and reuses the same `discover_runs` "latest run per label" model.

There is no application to build — a Helm chart, a few bash modules, one host driver,
and one Python report script. It reuses the repo's **shared image** (the root-level
[Dockerfile](../Dockerfile), which now also carries `sysbench` + `fio`).

## Commands

Chart lives under `node-perf/node-perf`. From `node-perf/`:

```bash
helm lint node-perf
helm template t node-perf                                  # render all manifests
helm template t node-perf --set 'nodes={a,b}'              # two nodes -> two pods
helm template t node-perf --set benchmarks.disk.enabled=false   # exercise a toggle
helm install node-perf node-perf -n <ns>
```

Validate scripts without a cluster:

```bash
bash -n node-perf/files/node_bench.sh node-perf/files/lib.sh \
        node-perf/files/bench_cpu.sh node-perf/files/bench_mem.sh \
        node-perf/files/bench_disk.sh run_suite.sh
python3 -m py_compile node-perf/files/report.py
# report against synthetic run dirs (needs matplotlib+numpy):
python3 node-perf/files/report.py <results_dir> report
```

Running is driven by [run_suite.sh](run_suite.sh) (host-side, uses `oc`); it assumes
the chart is installed. It finds the pods by label, execs `node_bench.sh run <label>
<note>` in each, and with `--report` gathers every node's results into one pod, runs
`report.py`, and copies `report.html` back:

```bash
./run_suite.sh -n <ns> --label baseline --note "stock" --report
./run_suite.sh -n <ns> --label tuned    --note "governor=performance" --report
```

## Architecture

### Two axes meeting in one data layout
- **Benchmark types** (what test): CPU, memory, disk — each a pluggable module
  (`bench_<x>.sh`), toggled in `values.benchmarks`.
- **Labels** (which config): `baseline`, `tuned`, … — chosen per run via
  `run_suite.sh --label`. The report compares the latest run of each label and
  computes a Δ% against the baseline label.

Both converge on a per-run directory (node-local; gathered before reporting):
```
/results/<label>-<timestamp>/
  setup.json            # node, kernel, cpu_model, cores, mem, governor, hugepages,
                        #   thp, tuned, numa_nodes, label, note, date, env_label
  cpu/{raw.txt, metrics.json}
  mem/{raw.txt, metrics.json}
  disk/{<job>.json, metrics.json}
  full.log
/results/report/        # report.html + *.png + data/metrics.csv
```

### The metrics.json contract (why it's pluggable)
Every module emits **`<group>/metrics.json`**, the ONLY thing the report reads:
```json
{"group":"cpu","benchmark":"sysbench-cpu",
 "metrics":[{"name":"events_per_sec","dim":"","unit":"events/s","value":48210.5,"higher_is_better":true}]}
```
Metric identity is `(group, name, dim)`. `dim` is a sub-dimension (fio `randread`,
sysbench-mem `read-seq`). `higher_is_better` drives the report's improvement/
regression colouring. **Adding a benchmark = drop a `bench_<x>.sh` that emits one of
these + wire its env in the chart; `node_bench.sh` and `report.py` need no change.**

### How parameters flow
`values.yaml` → rendered into pod **env vars** by `node-perf.env` in
[templates/_helpers.tpl](node-perf/templates/_helpers.tpl) → read by the module
scripts. Lists render space-joined (`MEM_OPER`, `MEM_MODE`); disk jobs serialize as
`name:rw:bs:iodepth` tokens (`DISK_JOBS`). `NODE_NAME` comes from the downward API
(`spec.nodeName`) so `setup.json` records the real node, not the pod name. **Change a
default in two places or neither**: the values schema and the script's env defaults.

### The runner (in-pod)
- [node_bench.sh](node-perf/files/node_bench.sh) `run <label> <note>` — makes the run
  dir, writes `setup.json` (via `collect_setup`), tees everything to `full.log`, then
  runs **every `bench_*.sh` next to it** (auto-discovered — each module self-gates on
  its own `<X>_ENABLED`). This is the "pipeline": drop-in modules, no central registry.
- [lib.sh](node-perf/files/lib.sh) — shared helpers: `make_run_dir`, `collect_setup`
  (uname/lscpu/governor/hugepages/thp/tuned/numa → setup.json via a python json.dump),
  and the metric accumulator (`metric_begin` / `metric_add name dim unit value hib` /
  `metric_flush group benchmark outfile`).
- [bench_cpu.sh](node-perf/files/bench_cpu.sh) — `sysbench cpu`; parses events/sec +
  latency avg/p95.
- [bench_mem.sh](node-perf/files/bench_mem.sh) — `sysbench memory` over `oper × mode`;
  parses throughput MiB/s + p95 latency, one dim per combo.
- [bench_disk.sh](node-perf/files/bench_disk.sh) — `fio --direct=1
  --output-format=json` per job; parses IOPS + bandwidth + clat p50/p99 via **`jq`**
  (summing read+write sides so pure jobs work), one dim per job.

### Storage (`results`)
`node-perf.volumes` picks the backend by precedence: `results.pvcName` (shared PVC) →
`results.hostPath` (node-local, persistent; the default) → `emptyDir`. Pods on
different nodes write node-local, so `run_suite.sh --report` **gathers** every pod's
run dirs into the first pod (streams a `tar` over `oc exec`) before plotting — no
shared PVC needed. `diskScratch.hostPath` is a separate node-local mount fio targets
(the real disk under test), always exercised with `--direct=1`.

### Report ([report.py](node-perf/files/report.py))
`discover_runs` (copied from the RoCE plotter) finds the latest run per label. Then it
is **fully metric-driven**: glob every run's `*/metrics.json`, index by
`(group, name, dim)`, and for each metric emit a grouped bar (x = dims, group = label)
+ a comparison table with **Δ% vs baseline**, coloured `.up`/`.down` by whether the
delta is an improvement given `higher_is_better`. A "runs & node configuration" table
(from `setup.json`) documents *what changed* between labels. `export_all_data` writes
one flat `data/metrics.csv`. The stylesheet (`REPORT_CSS`) is self-contained and
theme-aware (copied from the RoCE plotter). Baseline label = `REPORT_BASELINE` env
(set by the chart / overridden by `run_suite.sh --baseline`), falling back to the
first run.

### Shared template plumbing
[_helpers.tpl](node-perf/templates/_helpers.tpl) holds `node-perf.env` (params),
`node-perf.container` (image, `command`, `NODE_NAME` downward-API env, `privileged`,
resources — **empty by default so the pod sees the whole node**, and the scripts /
results / disk-scratch mounts), and `node-perf.volumes` (the `-scripts` ConfigMap at
mode `0555` + results PVC/hostPath/emptyDir + the disk-scratch hostPath).
[pods.yaml](node-perf/templates/pods.yaml) stamps one idle Pod per `values.nodes`.
[configmap.yaml](node-perf/templates/configmap.yaml) globs **all** of `files/` via
`.Files.Glob`, so adding a script there auto-mounts it under `script.mountPath`
(`/opt/node-perf`). `run_suite.sh` lives at the subject root, **not** under `files/` —
it runs on your laptop, not in the pods.

### Conventions
- **One idle pod per node**, pinned by `kubernetes.io/hostname`; no Multus/GPU/rail
  resources (unlike RoCE — these benchmarks only need CPU/memory/the node disk).
- **Labels are the comparison axis.** `discover_runs` keeps only the latest run per
  label, so baseline and tuned MUST use different labels. Benchmark one node at a time
  or encode the node in the label for multi-node.
- **No resource limits for node tuning.** A CPU/memory `limit` makes sysbench/fio
  measure the pod's cgroup slice, not the machine — the opposite of RoCE's
  Guaranteed-QoS NUMA-pinning advice. Keep `resources.{cpu,memory}` empty.
- **fio measures the real device**: `diskScratch.hostPath` + `--direct=1`.
- **Reuses the shared image** (needs the `sysbench`/`fio` added to the root
  [Dockerfile](../Dockerfile)) — see the repo-level [README](../README.md).

## Deferred / not yet built

- **Network** (iperf3 — already in the shared image) and **stress-ng soak** modules —
  trivial follow-ons via the same `bench_<x>.sh` + `metrics.json` pattern.
- Optional later refactor to lift the generic `report.py` + results contract into a
  repo-level shared framework the RoCE subject could also adopt (kept out of scope to
  avoid touching the working RoCE plotter).

## Notes
- OpenShift-oriented (`oc`), but `kubectl` works for the generic bits.
- The shared benchmark image ([Dockerfile](../Dockerfile), at the repo root) is the
  repo's global image — see the repo-level [README](../README.md).
