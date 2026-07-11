# Node performance-tuning benchmark

Measures a node's **CPU, memory, and disk** performance and shows the **effect of
a tuning change** as a before/after comparison. You run a **baseline**, change one
knob (cpufreq governor, hugepages, a `tuned` profile, NUMA, a kernel cmdline flag,
…), run again as **tuned**, and the report renders every metric side-by-side with a
**Δ% vs baseline** — coloured green for an improvement, red for a regression.

Off-the-shelf tools: **sysbench** (CPU + memory) and **fio** (disk). Sibling subject
to [RoCE-tests-chart/](../RoCE-tests-chart/); it reuses the same shared image (which
now also carries sysbench + fio) and the same "idle pods + `oc` driver + gathered
report" pattern.

> Architecture and contributor details live in [CLAUDE.md](CLAUDE.md).

## How it works

The chart stamps one **idle pod per node** you list in
[node-perf/values.yaml](node-perf/values.yaml) (`nodes:`). A host-side
[run_suite.sh](run_suite.sh) execs the in-pod runner, which runs every enabled
benchmark module and writes a self-describing result dir. Runs are keyed by a
**label**; the report compares the latest run of each label.

```text
/results/<label>-<timestamp>/
  setup.json            # node, kernel, cpu, mem, governor, hugepages, thp, tuned, note, date
  cpu/{raw.txt, metrics.json}
  mem/{raw.txt, metrics.json}
  disk/{<job>.json, metrics.json}
  full.log
```

`metrics.json` is the only contract the report reads, so adding a benchmark is just
dropping a new `bench_<x>.sh` (see CLAUDE.md).

## Prerequisites

- OpenShift/Kubernetes with `oc` (or `kubectl`) access to the target namespace.
- The shared benchmark image built/pushed **with sysbench + fio** (tag `:v3`; see
  the repo-level [README](../README.md) → Shared components). Set `image:` in values.
- Pods run **privileged** so `fio` can open the node's real device with `O_DIRECT`.
  Grant it once per namespace:
  ```bash
  oc adm policy add-scc-to-user privileged -z default -n <ns>
  ```
- A node-local scratch path for fio (`diskScratch.hostPath`) on the disk you want to
  characterize. Results are node-local `hostPath` by default (no shared PVC needed —
  `run_suite.sh --report` gathers each node's results before plotting).

## Quickstart

Run from the **repo root** — the shared `run_suite.sh` dispatcher forwards to this
subject's driver (`./run_suite.sh node-perf …` ≡ `./node-perf/run_suite.sh …`):

```bash
# 1. set your nodes + disk scratch in values.yaml, then install:
helm install node-perf node-perf/node-perf -n <ns>
oc adm policy add-scc-to-user privileged -z default -n <ns>

# 2. baseline (stock config)
./run_suite.sh node-perf -n <ns> --label baseline --note "stock" --report

# 3. make your tuning change on the node(s):
#      cpufreq governor, hugepages, tuned profile, NUMA, kernel cmdline, ...

# 4. re-run under a NEW label — the report compares it against baseline
./run_suite.sh node-perf -n <ns> --label tuned --note "governor=performance" --report

# 5. open the report
open ./report/report.html
```

The driver is "drive only" — it assumes the chart is already installed. Flags (passed
straight through the dispatcher):

| flag | meaning |
|------|---------|
| `-n, --namespace` | namespace the chart is installed in (required) |
| `--label <name>` | tags the run dir; **use a different label per config you compare** (default `baseline`) |
| `--note "<text>"` | free-text describing this run's config (shown in the report) |
| `--baseline <label>` | which label deltas are computed against (default `baseline`) |
| `--report` | gather results, build `report.html`, copy it to `--out` |
| `--out <dir>` | output directory for `--report` (default `./report`) |

## Configuring the matrix

All in [node-perf/values.yaml](node-perf/values.yaml):

- `nodes` — one idle benchmark pod is stamped per node. Benchmark **one node at a
  time** for a clean baseline-vs-tuned comparison, or list several and encode the
  node in `--label` (e.g. `node03-baseline`) so runs don't collide.
- `benchmarks.cpu` — `sysbench cpu`: `threads` (0=all cores), `time`, `maxPrime`.
- `benchmarks.memory` — `sysbench memory`: `threads`, `time`, `blockSize`,
  `totalSize`, and the `oper` × `mode` cross product (read/write × seq/rnd).
- `benchmarks.disk` — `fio` (`--direct=1`): `engine`, `time`, `size`, and a list of
  `jobs` (`name`, `rw`, `bs`, `iodepth`). Each job → IOPS + bandwidth + clat p50/p99.
- `diskScratch.hostPath` — the **real node path** fio reads/writes (the disk under
  test). Point it at the device/mount you're tuning.
- `resources.{cpu,memory}` — **leave empty for node tuning.** A CPU/memory limit
  makes sysbench/fio measure the pod's cgroup slice, not the whole node.
- `report.baselineLabel` — default baseline label for the Δ% comparison.

Toggle any benchmark off with its `.enabled: false`.

## Output

```text
/results/<label>-<timestamp>/   # one per run (per node, per label)
  setup.json  cpu/  mem/  disk/  full.log
/results/report/
  report.html                   # runs/config table + per-metric bars + Δ% tables
  *.png                          # every chart
  data/metrics.csv              # ALL metrics flat: label,group,metric,dim,unit,value,delta%
```

## Manual run (without the driver)

```bash
oc exec -n <ns> node-perf-0 -- \
  bash /opt/node-perf/node_bench.sh run baseline "stock"
# ...then gather + report as run_suite.sh --report does, or copy /results out.
```

## Troubleshooting

- **fio numbers look like RAM speed** — `diskScratch.hostPath` is pointing at a
  tmpfs/overlay, or `--direct` isn't taking. It must be a real block-device path on
  the node. fio always runs with `--direct=1` here.
- **sysbench sees fewer cores / less memory than the node** — the pod has a CPU/mem
  `limit`. For node tuning, clear `resources.cpu`/`resources.memory` so the pod is
  BestEffort and sees the whole machine.
- **`no run directories found`** — run with `--report` (it gathers each node's
  node-local results into one pod first), and make sure both runs used **different**
  labels (the report keeps only the latest run per label).
- **`fio not found` / `sysbench: command not found`** — the pod is on an old image.
  Rebuild/push the shared image `:v3` (it adds sysbench + fio) and set `image:`.
