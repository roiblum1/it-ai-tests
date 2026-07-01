# RoCE leaf/spine RDMA benchmark

Measures the cost of crossing the **spine** on a Port2Port RoCEv2 fabric. It runs
a 1-to-1 RDMA benchmark between a server and two clients at once — one client on
the **same leaf** as the server, one on a **different leaf** (its traffic crosses
the spine) — and renders side-by-side graphs so the spine hop's BW/latency cost is
visible.

It runs a configurable `perftest` matrix (read/write bandwidth, write/read/send
latency), optionally over **GPUDirect** (`--use_cuda`), plus an optional **NCCL**
one-HCA-vs-all test.

> Architecture and contributor details live in [CLAUDE.md](CLAUDE.md).

## Scope

Implemented now — the **1-to-1** server↔client flow: basic RDMA bandwidth/latency
perfs, GPUDirect, and the NCCL one-vs-many test, across same-leaf and
spine-crossing. **Not built yet:** many-to-many (env 2.3) and
tail-latency-under-load (env 2.4) — to be added once the 1-to-1 flow is finalized.

## How the topology maps

Each node has 8 RoCE rails (one NIC per GPU). Every rail is its own SR-IOV
device-plugin resource and its own Multus NAD; the first 4 rails are on leaf 1,
the next 4 on leaf 2. So **leaf vs spine is just which nic each endpoint uses**.

You describe each endpoint in [roce-perf/values.yaml](roce-perf/values.yaml) with a
`node` (k8s hostname, for scheduling), a `nic` (the rail → device-plugin resource),
and a `nad` (the NetworkAttachmentDefinition). The NAD's node-token usually differs
from the hostname (host `ocp4-…-h200-03` → NAD `roce-h200-3-ens32`), so set it
explicitly; omit it to fall back to `topology.nadPattern`:

```yaml
topology:
  nadPattern: "roce-{node}-{nic}"                     # fallback when an endpoint omits nad
  resourcePattern: "openshift.io/rdma_resource_{nic}" # -> openshift.io/rdma_resource_ens32
  device: mlx5_0                                       # in-pod device; "auto" detects the VF

scenario:
  server:   { node: ocp4-...-h200-03, nic: ens32, nad: roce-h200-3-ens32 }  # leaf 1
  sameLeaf: { node: ocp4-...-h200-04, nic: ens32, nad: roce-h200-4-ens32 }  # leaf 1 -> no spine
  spine:    { node: ocp4-...-h200-04, nic: ens36, nad: roce-h200-4-ens36 }  # leaf 2 -> spine
```

## Prerequisites

- OpenShift with the **SR-IOV RDMA** operator configured so each rail exposes a
  per-nic resource (`openshift.io/rdma_resource_<nic>`) and a NAD per (node, rail).
- The pods run **privileged** (so in-pod `ping`/`traceroute` work). Grant it:
  ```bash
  oc adm policy add-scc-to-user privileged -z default -n <ns>
  ```
- The shared CUDA benchmark image built/pushed from [Dockerfile](Dockerfile) (see
  the repo-level [README](../README.md)). Set `image:` in values to your registry.
- Results storage — **node-local `hostPath`** by default (`results.hostPath`,
  persists on the node). No shared PVC needed: `run_suite.sh --report` gathers each
  client's run dirs into the server before plotting. (Only the optional in-cluster
  report Job needs an RWX `results.pvcName`.)
- For GPUDirect / NCCL: a **GPU** on the nodes (`gpudirect.enabled` adds a
  `nvidia.com/gpu` request).

## Quickstart

```bash
# 1. set your topology in values.yaml (scenario.{server,sameLeaf,spine}.{node,nic,nad}
#    and results.hostPath), then install:
helm install demo roce-perf -n <ns>

# 2. allow privileged pods (once per namespace)
oc adm policy add-scc-to-user privileged -z default -n <ns>

# 3. drive the whole run from your machine: discovers the server IP, runs both
#    clients, builds the report, and copies report.html to ./report
./run_suite.sh -n <ns> --report

# 4. open the report
open ./report/report.html
```

`run_suite.sh` is "drive only" — it assumes the chart is already installed. It
waits for the pods, auto-discovers the server's RoCE IP (`oc exec rdma-server --
ip -br a`), and runs each client with the device auto-detected.

## Configuring the matrix

All in [roce-perf/values.yaml](roce-perf/values.yaml):

- `benchmarks.bw.{read,write}` — `enabled`, `duration` (`-D`), `sizes` (`-s`), `qps` (`-q`)
- `benchmarks.lat.{write,read,send}` — `enabled`, `iters` (`-n`), `size`, `unsorted` (`-U`)
- `gpudirect.{enabled,gpuIndex}` — re-run the matrix with `--use_cuda`; `gpudirect.skip` lists tests to omit from the CUDA pass only (default `[send_lat]`, which still runs on the NIC)
- `nccl.*` — one-HCA-vs-all (gated off by default; needs ssh between pods)
- `report.enabled` — run the plot Job in-cluster instead of via `run_suite.sh --report`

## Output

Each client writes a per-run directory to its node-local results dir (`run_suite.sh
--report` gathers both into the server before plotting):

```
/results/<env-label>-<timestamp>/      # env-label = same-leaf | spine-crossing
  setup.json                           # what was tested + environment
  bw/{read,write}_bw.csv               # size,duration,bw_peak,bw_avg,msg_rate
  lat/<test>.unsorted.txt + .json      # raw -U samples + min/avg/p50/p99/p999/max
  gpudirect/{bw,lat}/...               # same tree when gpudirect.enabled
  full.log
/results/report/report.html            # graphs: BW bars, latency CDFs, percentile table
```

## Manual run (without the driver)

After `helm install`, the install notes ([NOTES.txt](roce-perf/templates/NOTES.txt))
print the exact `oc exec` steps: get the server IP, run `roce_bench.sh client auto
<ip> <env>` from each client, then `plot_report.py` for the report.

## Troubleshooting

- **`ping: Operation not permitted`** — the pod isn't privileged. Grant the
  `privileged` SCC (above); RoCE itself doesn't use ICMP, so RDMA tests still run.
- **Pods stuck `Pending`** — the requested `openshift.io/rdma_resource_<nic>` isn't
  available on the chosen node, or the `nad` doesn't exist. Check the SR-IOV
  policy/NADs and your `scenario` `nic`/`nad` values.
- **`no run directories with setup.json`** — generate the report with
  `run_suite.sh --report` (it gathers both clients' results into the server first).
  Running `plot_report.py` directly only sees one node's results unless
  `results.pvcName` is a shared RWX PVC.
