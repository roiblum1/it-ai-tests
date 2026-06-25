# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Helm chart, `roce-perf` (at [RoCE-tests-chart/roce-perf/](RoCE-tests-chart/roce-perf/)), that deploys a RoCEv2 leaf/spine RDMA benchmark harness onto OpenShift, plus a [Dockerfile](RoCE-tests-chart/Dockerfile) for the one CUDA-enabled image every pod uses.

The harness benchmarks a **1-to-1** server↔client pair across two environments at once: a client whose VF is on the **same leaf** as the server, and one whose VF is on a **different leaf** (traffic crosses the **spine**). Comparing the two shows the cost of the spine hop. It runs a configurable matrix of `perftest` tests (BW + latency), optionally over GPUDirect, plus an optional NCCL one-HCA-vs-all test, and renders comparison **graphs**.

Targets SR-IOV RDMA with **exactly one VF per pod**. Pods reach RoCE networks through Multus NADs (`NetworkAttachmentDefinition`), referenced via the `k8s.v1.cni.cncf.io/networks` annotation. There is no application to build — YAML/templates, one bash benchmark runner, and one Python plotting script.

## Commands

Chart lives under `RoCE-tests-chart/roce-perf`. From `RoCE-tests-chart/`:

```bash
helm lint roce-perf
helm template demo roce-perf                  # render all manifests (no cluster)
helm template demo roce-perf --set gpudirect.enabled=true   # exercise a gate
helm template demo roce-perf -s templates/report-job.yaml --set report.enabled=true --set results.pvcName=x
helm install demo roce-perf -n <ns>
```

Build the image (NVIDIA CUDA Ubuntu base, ~8GB; CUDA + NCCL + OpenMPI come prebuilt via apt. Only perftest (plain + CUDA) is compiled at image-build time. nccl-tests ships as **source** and is built on first NCCL run on a GPU node — `nvcc` segfaults under x86 emulation so it can't be cross-built on an ARM Mac. No Red Hat subscription needed):

```bash
docker build -t <registry>/rdma-tools-cuda:latest RoCE-tests-chart/
```

Validate scripts without a cluster:

```bash
bash -n roce-perf/files/roce_bench.sh
python3 -m py_compile roce-perf/files/plot_report.py
# plotter against synthetic/real run dirs:
python3 roce-perf/files/plot_report.py <results_dir> report   # needs matplotlib+numpy
```

Running the actual benchmark is a manual `oc exec` flow on the live pods (the chart stages them). Canonical steps are emitted by [templates/NOTES.txt](RoCE-tests-chart/roce-perf/templates/NOTES.txt) on install: find the server's RoCE IP from its `network-status` annotation, `oc exec` each client to run `roce_bench.sh client …`, then run the report Job for graphs.

## Architecture

### Two axes meeting in one data layout
- **Benchmark types** (what test): read/write BW, write/read/send latency, each optionally re-run over GPUDirect; plus NCCL. Defined in `values.benchmarks`, `values.gpudirect`, `values.nccl`.
- **Environments** (where): `same-leaf` and `spine-crossing`, expressed by which NAD each client pod attaches to (`values.pods[].network`) and tagged by `values.pods[].label`.

Both axes converge on a per-run directory written to the shared results PVC, which the report Job reads back:
```
/results/<env-label>-<timestamp>/
  setup.json                      # env, device, node, mtu, gpudirect, params, date  (the "setup summary")
  bw/{read,write}_bw.csv          # size,duration,bw_peak,bw_avg,msg_rate
  lat/<test>.unsorted.txt         # raw -U latency samples (sorted later for CDF/percentiles)
  lat/<test>.json                 # min/avg/p50/p99/p999/max
  gpudirect/{bw,lat}/...          # same tree when gpudirect.enabled
  full.log
/results/report/                  # report Job output: PNGs + report.html
```

### How parameters flow
`values.yaml` → rendered into pod **env vars** by the `roce-perf.env` template in [templates/_helpers.tpl](RoCE-tests-chart/roce-perf/templates/_helpers.tpl) → consumed by `roce_bench.sh`. The script's env contract (`BW_READ_*`, `LAT_WRITE_*`, `GPUDIRECT_ENABLED`, `NCCL_*`, …) is documented at the top of [files/roce_bench.sh](RoCE-tests-chart/roce-perf/files/roce_bench.sh). **Change a default in two places or neither**: the values schema and the script's env defaults — keep them aligned.

### The runner ([roce_bench.sh](RoCE-tests-chart/roce-perf/files/roce_bench.sh))
Server and client both call `build_plan`, which deterministically assigns a **port per (test, size)** from the same env — so the two sides agree on ports with no negotiation. This is the key invariant: perftest requires the client's flags to **match** the listening server, and identical `build_plan` output guarantees it. `add_bw`/`add_lat` append `subtree|family|name|port|binary|size|flags|type` rows; a second pass appends `--use_cuda` rows into the `gpudirect` subtree when enabled. Server backgrounds a `while true` listener per row; client runs each and writes BW CSV rows or latency `*.unsorted.txt` (+ `summarize_samples` → `.json`).

### Report Job ([report-job.yaml](RoCE-tests-chart/roce-perf/templates/report-job.yaml) + [plot_report.py](RoCE-tests-chart/roce-perf/files/plot_report.py))
Gated by `report.enabled`; **fails template rendering if `results.pvcName` is unset** (an emptyDir can't be shared across pods). Mounts the PVC, picks the latest run per env-label, and emits BW grouped bars, latency CDF overlays (sorted from the `-U` samples), a percentile table, GPUDirect sections, and an NCCL bar, into `report.html`.

### Shared template plumbing
[_helpers.tpl](RoCE-tests-chart/roce-perf/templates/_helpers.tpl) holds `roce-perf.env` (the params block), `roce-perf.container` (image, `command` as a JSON list, `IPC_LOCK`, the `rdmaResourceName: "1"` request/limit, **and `nvidia.com/gpu: "1"` when `gpudirect.enabled`**), and `roce-perf.volumes` (the `-scripts` ConfigMap at mode `0555` + results PVC/emptyDir). Change pod shape here, not in each template. [configmap.yaml](RoCE-tests-chart/roce-perf/templates/configmap.yaml) globs **all** of `files/` via `.Files.Glob`, so adding a script there auto-mounts it under `script.mountPath` (`/opt/roce`).

### Conventions
- **One VF per pod** via `values.rdmaResourceName: "1"`; `ipcLock: true` adds `IPC_LOCK` for RDMA memory registration.
- **Topology = which NAD**, not node placement: `roce-net-leaf` vs `roce-net-spine` is what makes a client same-leaf vs spine-crossing.
- **GPUDirect/NCCL need the CUDA image + a GPU**; enabling `gpudirect` adds a `nvidia.com/gpu` request to every pod.

## Deferred / not yet built
- Env 2.3 **many-to-many** (the `mesh.enabled` scaffold in [templates/mesh.yaml](RoCE-tests-chart/roce-perf/templates/mesh.yaml) stamps idle pods but has no orchestrator) and 2.4 **tail-latency-under-load**.
- Any automated coordinator (IP discovery / pairing / concurrent launch) — the 1-to-1 flow is manual `oc exec`.
- NCCL ([nccl_one_vs_many.sh](RoCE-tests-chart/roce-perf/files/nccl_one_vs_many.sh)) is gated off; it needs `sshd` up on both pods + key auth for `mpirun`.

## Notes
- OpenShift-oriented (`oc`), but `kubectl` works for the generic bits.
- `it-ai-test.zip` (~94 MB) is unrelated to the chart — do not unzip or modify it.
