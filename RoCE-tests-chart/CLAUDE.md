# CLAUDE.md — RoCE leaf/spine RDMA benchmark

This file guides Claude Code (claude.ai/code) when working in this subject. It is
the **RoCE benchmark subject** of a multi-subject benchmark repo — see the
repo-level [README](../README.md) for the collection and this folder's
[README](README.md) for the user-facing quickstart. This file is the architecture
/ contributor guide.

## What this is

A single Helm chart, `roce-perf` (at [RoCE-tests-chart/roce-perf/](roce-perf/)), that deploys a RoCEv2 leaf/spine RDMA benchmark harness onto OpenShift, plus a [Dockerfile](Dockerfile) for the one CUDA-enabled image every pod uses.

The harness benchmarks a **1-to-1** server↔client pair across two environments at once: a client whose VF is on the **same leaf** as the server, and one whose VF is on a **different leaf** (traffic crosses the **spine**). Comparing the two shows the cost of the spine hop. It runs a configurable matrix of `perftest` tests (BW + latency), optionally over GPUDirect, plus an optional NCCL one-HCA-vs-all test, and renders comparison **graphs**.

Targets a **Port2Port** SR-IOV RDMA fabric with **exactly one VF per pod**. Each node has 8 RoCE rails (one NIC per GPU); each rail is its own device-plugin resource (`openshift.io/rdma_resource_<nic>`) and its own Multus NAD (`<node>-<nic>`, carrying that rail's exclusive IP + next hop). The first 4 rails land on leaf 1, the next 4 on leaf 2 — so **leaf vs spine is purely which nic an endpoint uses**. NADs are referenced via the `k8s.v1.cni.cncf.io/networks` annotation. There is no application to build — YAML/templates, one bash benchmark runner, one host-side driver script, and one Python plotting script.

## Commands

Chart lives under `RoCE-tests-chart/roce-perf`. From `RoCE-tests-chart/`:

```bash
helm lint roce-perf
helm template demo roce-perf                  # render all manifests (no cluster)
helm template demo roce-perf --set gpudirect.enabled=true   # exercise a gate
helm template demo roce-perf -s templates/report-job.yaml --set report.enabled=true --set results.pvcName=x
helm install demo roce-perf -n <ns>
```

Build the image (NVIDIA **CUDA 13** devel Ubuntu base — must match the node driver's CUDA level, e.g. driver 580 → CUDA 13; a stale base makes perftest `--use_cuda` segfault and NCCL fall back to sockets. CUDA + NCCL + OpenMPI + OpenSSH come prebuilt via apt. Only perftest (plain + CUDA) is compiled at build time. nccl-tests ships as **source** and is built on first use by `run_suite --nccl` on both GPU pods — `nvcc` segfaults under x86 emulation so it can't be cross-built on an ARM Mac. Tag: `it-ai-rdma-perf:v2`):

```bash
docker build -t <registry>/rdma-tools-cuda:latest RoCE-tests-chart/
```

Validate scripts without a cluster:

```bash
bash -n roce-perf/files/roce_bench.sh
bash -n run_suite.sh
python3 -m py_compile roce-perf/files/plot_report.py
# plotter against synthetic/real run dirs:
python3 roce-perf/files/plot_report.py <results_dir> report   # needs matplotlib+numpy
```

Running the benchmark is driven by [run_suite.sh](run_suite.sh) (host-side, uses `oc`), which assumes the chart is already installed. It waits for the pods, auto-discovers the server RoCE IP (`oc exec rdma-server -- ip -br a`, picking the Multus VF netdev), `oc exec`s each client to run `roce_bench.sh client auto <ip> <env>`, and with `--report` generates `report.html` and copies it back locally:

```bash
./run_suite.sh -n <ns> --report
```

The equivalent manual `oc exec` steps are emitted by [templates/NOTES.txt](roce-perf/templates/NOTES.txt) on install.

## Architecture

### Two axes meeting in one data layout
- **Benchmark types** (what test): read/write BW, write/read/send latency, each optionally re-run over GPUDirect; plus NCCL. Defined in `values.benchmarks`, `values.gpudirect`, `values.nccl`.
- **Environments** (where): `same-leaf` and `spine-crossing`, chosen per endpoint in `values.scenario` (`server`/`sameLeaf`/`spine`), each with `node` (k8s hostname → scheduling), `nic` (→ resource via `topology.resourcePattern`), and `nad` (the NAD name; the node-token usually differs from the hostname, so it's explicit, falling back to `topology.nadPattern`).

Both axes converge on a per-run directory written to each pod's node-local results dir (see Storage below), which the report reads back:
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
`values.yaml` → rendered into pod **env vars** by the `roce-perf.env` template in [templates/_helpers.tpl](roce-perf/templates/_helpers.tpl) → consumed by `roce_bench.sh`. The script's env contract (`BW_READ_*`, `LAT_WRITE_*`, `GPUDIRECT_ENABLED`, `NCCL_*`, …) is documented at the top of [files/roce_bench.sh](roce-perf/files/roce_bench.sh). **Change a default in two places or neither**: the values schema and the script's env defaults — keep them aligned.

### The runner ([roce_bench.sh](roce-perf/files/roce_bench.sh))
Server and client both call `build_test_plan`, which deterministically assigns a **port per (test, size)** from the same env — so the two sides agree on ports with no negotiation. This is the key invariant: perftest requires the client's flags to **match** the listening server, and identical plan output guarantees it. `add_bw_test`/`add_lat_test` append `subtree|family|name|port|binary|size|flags|kind` rows; a second pass appends `--use_cuda` rows into the `gpudirect` subtree when enabled. Server backgrounds a `while true` listener per row; client runs each and writes BW CSV rows or latency `*.unsorted.txt` (+ `summarize_latency` → `.json`). The `<device>` arg may be `auto` (the default the chart passes) — `detect_rdma_device` then finds the pod's single VF under `/sys/class/infiniband`.

### Storage (`results`)
`roce-perf.volumes` picks the backend by precedence: `results.pvcName` (shared PVC) → `results.hostPath` (node-local, persists; the default) → `emptyDir`. The 1-to-1 pods are on different nodes, so with hostPath/emptyDir each pod's results are node-local. `run_suite.sh --report` therefore **gathers** every client's run dirs into the server pod (streams a `tar` over `oc exec`) before plotting — no shared PVC needed. The in-cluster report Job has no gather step, so it still requires a shared (RWX) PVC.

### Report ([report-job.yaml](roce-perf/templates/report-job.yaml) + [plot_report.py](roce-perf/files/plot_report.py))
`plot_report.py` scans `<results>/<env>-<ts>/` (latest per env-label) and emits BW grouped bars, latency **over-time** line plots (raw `-U` samples vs sample order, peak-preserving downsample — shows spikes), latency CDF overlays + histograms (log-y), a percentile table, GPUDirect sections, and an NCCL bar, into `report.html`. The usual path is `run_suite.sh --report` (gathers, runs the plotter on the server, copies the report out). The in-cluster Job alternative is gated by `report.enabled` and **fails template rendering if `results.pvcName` is unset**.

### Shared template plumbing
[_helpers.tpl](roce-perf/templates/_helpers.tpl) holds `roce-perf.env` (the params block), `roce-perf.container` (image, `command` as a JSON list, `privileged` + `IPC_LOCK`, a **per-pod** `<resource>: "1"` request/limit passed in via the call dict, **and `nvidia.com/gpu: "1"` when `gpudirect.enabled`**), and `roce-perf.volumes` (the `-scripts` ConfigMap at mode `0555` + results PVC/hostPath/emptyDir). Change pod shape here, not in each template. [pods.yaml](roce-perf/templates/pods.yaml) builds the 3-pod list from `values.scenario`, resolving each pod's NAD (explicit `nad` or `nadPattern`) + resource before calling the helper. [nccl-pods.yaml](roce-perf/templates/nccl-pods.yaml) (gated by `nccl.enabled`) stamps the two multi-rail NCCL pods with their own inline container (a **list** of rail resources) but reuses `roce-perf.env`/`.volumes`. [configmap.yaml](roce-perf/templates/configmap.yaml) globs **all** of `files/` via `.Files.Glob`, so adding a script there auto-mounts it under `script.mountPath` (`/opt/roce`). Note `run_suite.sh` lives at the chart-repo root, **not** under `files/` — it runs on your laptop, not in the pods.

### Conventions
- **One VF per pod**; the device-plugin resource is **derived per pod from the nic** via `topology.resourcePattern` (e.g. `openshift.io/rdma_resource_ens192`), not a single global value. `ipcLock: true` adds `IPC_LOCK`; `privileged: true` (default) makes in-pod `ping`/`traceroute` work under any SCC.
- **Topology = `(node, nic, nad, gpuIndex)`** per endpoint in `values.scenario.{server,sameLeaf,spine}`: same nic/leaf ⇒ same-leaf, a nic on the other leaf ⇒ spine-crossing. `nad` is explicit (its node-token usually differs from the k8s hostname), falling back to `nadPattern`. `gpuIndex` is the GPU paired with that rail (spine needs a different GPU than the leaf rails); it's rendered as a **per-pod** `GPU_INDEX` env by `roce-perf.container` (not the shared `roce-perf.env`), falling back to `gpudirect.gpuIndex`.
- **Results are node-local by default** (`results.hostPath`); the report is built by `run_suite.sh --report`, which gathers across nodes (see Storage). Only the in-cluster Job needs an RWX PVC.
- **GPUDirect/NCCL need the CUDA image + a GPU**; enabling `gpudirect` adds a `nvidia.com/gpu` request to every pod.
- **NUMA pinning** (`numactl.enabled`, default on): the runner wraps perftest in `numactl --cpunodebind/--membind` for the rail's socket, read per-pod from the NIC's `/sys/.../numa_node` when `numactl.node: auto`. It's best-effort — pins only if the cores are bindable (needs `resources.{cpu,memory}` for Guaranteed QoS + topology manager), else warns and runs unpinned.

## Deferred / not yet built

- Env 2.3 **many-to-many** and 2.4 **tail-latency-under-load** — not built yet; to be added after the 1-to-1 flow (basic perfs + GPUDirect + NCCL) is finalized. An earlier `mesh.yaml` scaffold was removed to keep scope tight.
- A multi-pair coordinator for many-to-many — `run_suite.sh` automates only the 1-to-1 flow (IP discovery + launching the two clients).
- **NCCL is wired** (off by default — heaviest path): `nccl.enabled` stamps `nccl-launcher`/`nccl-peer` (multi-rail, [nccl-pods.yaml](roce-perf/templates/nccl-pods.yaml)); `run_suite.sh --nccl` first **deletes the perftest pods** (they hold the GPUs/rails; hostPath results survive), applies **per-rail source routing** on both pods ([rail_routes.sh](roce-perf/files/rail_routes.sh) — multi-VF pods have overlapping supernet routes, so each rail gets its own table + `ip rule from <rail-ip>` + loose rp_filter) with a same-rail ping check, injects passwordless SSH, builds nccl-tests on both pods, and runs [nccl_one_vs_many.sh](roce-perf/files/nccl_one_vs_many.sh) (`mpirun` pinned to eth0 for its TCP bootstrap — `pml ob1`/`btl tcp` + `if_include` — one-HCA vs all, RoCE `-x` tuning incl. sysfs-detected `NCCL_IB_GID_INDEX`, preferring the **IPv4-mapped** RoCE v2 GID, typically index 3 — link-local v2 GIDs don't route across the /31 leaf gateways).

## Notes
- OpenShift-oriented (`oc`), but `kubectl` works for the generic bits.
- The CUDA benchmark image ([Dockerfile](Dockerfile)) is the shared/"global" image — see the repo-level [README](../README.md).
