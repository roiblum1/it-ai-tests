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

## How the topology maps

Each node has 8 RoCE rails (one NIC per GPU). Every rail is its own SR-IOV
device-plugin resource and its own Multus NAD; the first 4 rails are on leaf 1,
the next 4 on leaf 2. So **leaf vs spine is just which nic each endpoint uses**.

You describe the run as a `(node, nic)` per endpoint in
[roce-perf/values.yaml](roce-perf/values.yaml); the chart derives each pod's NAD
and resource from the nic:

```yaml
topology:
  nadPattern: "{node}-{nic}"                          # -> worker-1-ens192
  resourcePattern: "openshift.io/rdma_resource_{nic}" # -> openshift.io/rdma_resource_ens192
  device: mlx5_0                                       # in-pod device; "auto" detects the VF

scenario:
  server:   { node: worker-1, nic: ens192 }   # leaf 1
  sameLeaf: { node: worker-2, nic: ens192 }   # leaf 1  -> no spine
  spine:    { node: worker-2, nic: ens196 }   # leaf 2  -> crosses the spine
```

## Prerequisites

- OpenShift with the **SR-IOV RDMA** operator configured so each rail exposes a
  per-nic resource (`openshift.io/rdma_resource_<nic>`) and a per-(node,nic) NAD
  (`<node>-<nic>`).
- The pods run **privileged** (so in-pod `ping`/`traceroute` work). Grant it:
  ```bash
  oc adm policy add-scc-to-user privileged -z default -n <ns>
  ```
- The shared CUDA benchmark image built/pushed from [Dockerfile](Dockerfile) (see
  the repo-level [README](../README.md)). Set `image:` in values to your registry.
- For graphs across both environments: an **RWX PVC** (`results.pvcName`) so every
  pod's results are readable from one place.
- For GPUDirect / NCCL: a **GPU** on the nodes (`gpudirect.enabled` adds a
  `nvidia.com/gpu` request).

## Quickstart

```bash
# 1. install the chart with your topology + an RWX results PVC
helm install demo roce-perf -n <ns> \
  --set results.pvcName=<rwx-pvc> \
  --set scenario.server.node=worker-1   --set scenario.server.nic=ens192 \
  --set scenario.sameLeaf.node=worker-2 --set scenario.sameLeaf.nic=ens192 \
  --set scenario.spine.node=worker-2    --set scenario.spine.nic=ens196

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
- `gpudirect.{enabled,gpuIndex}` — re-run the matrix with `--use_cuda`
- `nccl.*` — one-HCA-vs-all (gated off by default; needs ssh between pods)
- `report.enabled` — run the plot Job in-cluster instead of via `run_suite.sh --report`

## Output

Each client writes a per-run directory to the results PVC:

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
  available on the chosen node, or the NAD `<node>-<nic>` doesn't exist. Check the
  SR-IOV policy/NADs and your `scenario` nics.
- **No graphs** — `results.pvcName` must be a single **RWX** PVC so the report can
  read every pod's run dir; an emptyDir can't be shared.
