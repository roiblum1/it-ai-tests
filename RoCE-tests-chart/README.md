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
a `nad` (the NetworkAttachmentDefinition), and — for GPUDirect — a `gpuIndex` (the
GPU **paired with that rail**, so the spine rail uses a different GPU than the leaf
rails; check `nvidia-smi topo -m`). The NAD's node-token usually differs from the
hostname (host `ocp4-…-h200-03` → NAD `roce-h200-3-ens32`), so set it explicitly;
omit `nad`/`gpuIndex` to fall back to `topology.nadPattern`/`gpudirect.gpuIndex`:

```yaml
topology:
  nadPattern: "roce-{node}-{nic}"                     # fallback when an endpoint omits nad
  resourcePattern: "openshift.io/rdma_resource_{nic}" # -> openshift.io/rdma_resource_ens32
  device: mlx5_0                                       # in-pod device; "auto" detects the VF

scenario:
  server:   { node: ocp4-...-h200-03, nic: ens32, nad: roce-h200-3-ens32, gpuIndex: 0 }  # leaf 1
  sameLeaf: { node: ocp4-...-h200-04, nic: ens32, nad: roce-h200-4-ens32, gpuIndex: 0 }  # leaf 1 -> no spine
  spine:    { node: ocp4-...-h200-04, nic: ens36, nad: roce-h200-4-ens36, gpuIndex: 4 }  # leaf 2 -> spine
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
#    clients, builds the report, and copies report.html to ./report.
#    add --nccl to also run the NCCL one-vs-many test (needs nccl.enabled=true).
#    NOTE: --nccl DELETES the perftest pods first, to free the GPUs/rails the
#    8-GPU NCCL pods need (they'd otherwise stay Pending). The perftest results
#    stay on the node hostPath and are still folded into the report, so this
#    needs results.hostPath (default) or a shared PVC -- NOT emptyDir.
./run_suite.sh -n <ns> --report            # perftest only
./run_suite.sh -n <ns> --nccl --report     # perftest, then NCCL (perftest pods removed)

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
- `gpudirect.{enabled,gpuIndex}` — re-run the matrix with `--use_cuda` (per-pod GPU is `scenario.*.gpuIndex`; `gpudirect.gpuIndex` is only the fallback). `gpudirect.skip` lists tests to omit from the CUDA pass only (default `[send_lat]`, which still runs on the NIC)
- `nccl.*` — one-HCA-vs-all across 2 nodes (gated off by default). `nccl.enabled`
  stamps a `nccl-launcher`/`nccl-peer` pair (each on `nccl.nodes[].host`, attached to
  `nccl.rails` + `nccl.gpus` GPUs). The launch is **one rank per GPU** (`-np =
  2×gpus`), the default sweep is a heavy `128M..8G`, and `nccl.ib.*` carries the RoCE
  tuning (GID index, socket iface, **traffic class**, **QPs/connection**, **PXN**,
  IB disable, debug). Run it with `run_suite.sh --nccl` (SSH + rail routing + builds
  nccl-tests on both + `mpirun`). **New to NCCL here? Read [NCCL-DEEP-DIVE.md](NCCL-DEEP-DIVE.md)**
  — what AllReduce measures, busbw vs algbw, what one-HCA-vs-all really compares, and
  why the same run reports 11 vs 174 GB/s.
- `numactl.{enabled,node}` — pin perftest to the rail's socket (`node: auto` reads the NIC's `numa_node` from sysfs per pod). For the bind to take real cores, set `resources.{cpu,memory}` (makes the pod Guaranteed QoS) + run the kubelet topology manager with `single-numa-node`; otherwise it warns and runs unpinned.
- `report.enabled` — run the plot Job in-cluster instead of via `run_suite.sh --report`

## Output

Each client writes a per-run directory to its node-local results dir (`run_suite.sh
--report` gathers both into the server before plotting):

```
/results/<env-label>-<timestamp>/      # env-label = same-leaf | spine-crossing
  setup.json                           # what was tested + environment
  bw/{read,write}_bw.csv               # size,duration,bw_peak,bw_avg,msg_rate
  lat/<test>.unsorted.txt + .json      # raw -U samples + min/avg/p50/p99/p999/max
  lat/<test>.raw.txt                   # FULL perftest stdout (plot falls back to this)
  nccl/{one_hca,all_hca}.txt + .json   # full nccl-tests tables + one/all busbw
  gpudirect/{bw,lat}/...               # same tree when gpudirect.enabled
  full.log
/results/report/
  report.html                          # BW bars + tables, latency over-time (peaks),
                                       #   CDFs, histograms, percentiles, NCCL busbw
                                       #   curve (per size) + one-vs-all bar
  *.png                                # every chart
  data/{bw,lat,nccl}_summary.csv       # ALL numbers, flat CSVs (external analysis)
  data/nccl_curve.csv                  # per-size algbw+busbw, one-HCA and all-HCA
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
- **No ping between VF IPs on the multi-rail (NCCL) pods** — with 8 VFs whose
  routes all point at the same fabric supernet, the main routing table picks ONE
  gateway for everything, so rail N's traffic egresses rail M and replies are
  dropped by `rp_filter`. `run_suite.sh --nccl` fixes this automatically by running
  [rail_routes.sh](roce-perf/files/rail_routes.sh) on both pods (per-rail source
  routing: one table + `ip rule from <rail-ip>` per VF, loose rp_filter). To check
  manually: `oc exec <pod> -- bash /opt/roce/rail_routes.sh`, then always pin the
  source — `ping -I <rail-ip> <peer-rail-ip>` (a bare `ping` still uses the main
  table). Single-VF perftest pods are unaffected (one route, no ambiguity).
- **NCCL falls back to sockets / cross-node QPs fail** — usually the GID index:
  a routed RoCEv2 fabric needs the **IPv4-mapped** RoCE v2 GID (`::ffff:<rail-ip>`,
  typically index 3), not the link-local one. `nccl.ib.gidIndex: auto` now detects
  exactly that; pin it (e.g. `3`) if your fabric differs. Set `nccl.ib.debug: INFO`
  to see the transport + GID NCCL actually picks.
- **NCCL `ibv_modify_qp failed ... errno 19 (No such device)`** — NCCL was handed
  an HCA that isn't a routable pod rail: either a device that isn't one of the
  pod's IP-bearing VFs (a privileged pod can see host RDMA devices in sysfs), or
  a rail the fabric doesn't route, so the IPv4-mapped GID index doesn't resolve on
  it. Fixed on two levels: HCA auto-detect maps the pod's **rail netdevs** to their
  RDMA devices (not a bare `/sys/class/infiniband` listing), and `run_suite.sh
  --nccl` restricts `NCCL_IB_HCA` to the rails that **passed the same-rail ping
  check** (aborting if none pass — that's a fabric problem, not a pod problem).
- **NCCL crashes with "No space left on device" / shared-memory allocation
  failure** — Kubernetes gives pods a **64Mi `/dev/shm`** by default and NCCL's
  host buffers exhaust it. The chart mounts a memory-backed `/dev/shm` in the NCCL
  pods (`nccl.shm.size`, default `8Gi`). As a last resort `nccl.shm.disable: "1"`
  sets `NCCL_SHM_DISABLE=1` (skips the SHM transport entirely).
