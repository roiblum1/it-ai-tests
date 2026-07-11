# NCCL benchmark deep dive — what we actually run, and how to read it

This explains the `nccl` test in this chart end to end: what the collectives
measure, what the numbers mean, what **one-HCA-vs-all** really compares (it is
*not* "which GPUs talk"), and why the same run can report **11 GB/s** or
**174 GB/s** depending only on the message sizes. Read this alongside
[values.yaml](roce-perf/values.yaml) (`nccl:` block) and
[nccl_one_vs_many.sh](roce-perf/files/nccl_one_vs_many.sh).

---

## 1. What the test is

We run one or more **`*_perf`** binaries from
[nccl-tests](https://github.com/NVIDIA/nccl-tests). `nccl.collectives` lists which
ones; **each is swept one-HCA vs all-HCA** over the message-size range, and for
each size the binary prints how long it took and two bandwidth numbers. Those
tables are the benchmark.

The default `all_reduce_perf` dominates data-parallel training: every GPU holds a
partial gradient, AllReduce sums them and returns the identical result to every
GPU — the most bandwidth-hungry step in a training iteration, so "how fast is my
fabric?" is, in practice, "how fast is AllReduce?".

### 1a. The collectives we run — and why

Each collective is a different **traffic pattern**, so running several profiles the
fabric against the shapes your real workloads produce (not just one number):

| Collective | Traffic shape | Maps to | Fabric stress |
|---|---|---|---|
| **all_reduce_perf** | reduce + broadcast (ring/tree) | tensor-parallel gradient/activation sync | canonical throughput; most fabric-sensitive |
| **alltoall_perf** | every rank → every rank | **wide-EP MoE** dispatch/combine | **the** rail-crossing exposer — no locality to hide behind |
| **reduce_scatter_perf** | reduce, each rank keeps a shard | TP + **sequence parallelism** (RS + AllGather, not AllReduce) | half of the SP communication pair |
| **sendrecv_perf** | point-to-point ring | **prefill→decode KV** transfer path | pairwise link bandwidth, no collective fan-out |

Why it matters here: **alltoall** has no same-leaf locality to exploit — every rank
must reach every other, so a fraction of flows *always* cross the spine. It's the
test that surfaces a weak spine or a mis-tuned rail the clearest. **sendrecv**
proxies the disaggregated prefill→decode KV hand-off, where a single pair's link
bandwidth (not aggregate collective busbw) is what bounds you.

The report draws a **cross-collective comparison** (all-HCA busbw vs size, all
collectives overlaid) so you can see them fan out — typically all_reduce ≥
reduce_scatter > alltoall ≈ sendrecv on a spine-bound fabric.

### The layout we launch (one rank per GPU)

```
mpirun -np 16 -H launcher:8,peer:8 --bind-to none --map-by slot ... all_reduce_perf -g 1
```

- **`-np 16`** = 16 MPI ranks = **one rank per GPU** (8 GPUs × 2 nodes). This is
  `nccl.gpus: 8` per node → `-np = 2 × gpus`.
- **`-g 1`** = each rank drives **1 GPU**. (The alternative, `-np 2 -g 8`, is one
  fat process per node; it under-uses the rails on this fabric, so we don't use it.)
- **Intra-node** the 8 local GPUs talk over **NVLink** (very fast, not the fabric).
- **Cross-node** is the part we care about — it goes over the **RoCE rails** (the
  8 SR-IOV VFs). *That* is what this benchmark is stressing.

So a "16-GPU AllReduce" here means: 16 GPUs in one collective, NVLink inside each
node, RoCE across the two nodes.

---

## 2. The two bandwidth numbers: algbw vs busbw

Each row of the output has **`algbw`** and **`busbw`**. They are different on
purpose.

- **algbw (algorithm bandwidth)** = `message_size / time`. Naive throughput: "how
  many bytes of *user* buffer per second". It does **not** account for the fact
  that AllReduce inherently moves each byte across the wire several times.

- **busbw (bus bandwidth)** = `algbw × 2(n−1)/n`, where `n` = number of ranks.
  This corrects for the AllReduce communication pattern (a ring moves ~2× the data
  across each link). **busbw is the number to compare against your link speed**,
  because it estimates the actual bytes-on-the-wire rate the hardware sustained.
  As `n` grows, `2(n−1)/n → 2`, so busbw ≈ 2 × algbw for large clusters.

**Rule of thumb:** busbw should approach the *aggregate* line rate of the rails
NCCL is using. Eight 400 Gb/s (≈50 GB/s) rails ≈ 400 GB/s of raw capacity; real
AllReduce busbw lands well under that after protocol/PFC/overhead — a few hundred
GB/s is healthy. **algbw < busbw always**; don't compare algbw to link rate.

The report's NCCL bar and `nccl.json` record the **`Avg bus bandwidth`** line that
nccl-tests prints at the end (the mean busbw across all sizes tested).

---

## 3. Why "11 GB/s" and "174 GB/s" are *both* real

This is the confusing part, and it is entirely about **which message sizes you
averaged over**.

busbw is near-zero for tiny messages (they are **latency-bound**: an 8-byte
AllReduce is dominated by round-trip time, not bandwidth) and only **saturates**
at large messages. So:

| Sweep (`-b`..`-e`) | What the AVG includes | Reported Avg busbw |
|---|---|---|
| `8` .. `128M` | ~15 tiny latency-bound sizes + a few big ones | **~11 GB/s** (dragged down) |
| `128M` .. `8G` | only saturated, bandwidth-bound sizes | **~150–174 GB/s** |

Neither number is "wrong" — they average different regions of the same curve. The
11 GB/s run wasn't slow hardware; it was **arithmetic** (a mean pulled down by the
small-message floor).

**What this chart now does:** `nccl.sizes` defaults to **`128M`..`8G`**, so the
reported average reflects the *fabric at saturation* — directly comparable to the
174 GB/s tuned run. If you want to *see* the ramp (latency floor → saturation),
lower `nccl.sizes.begin` to `8` and read the **per-size table**, not the average.

> Latency of the small messages is better measured by the **perftest** side of
> this chart (`ib_write_lat`/`ib_read_lat`, with the over-time + histogram plots),
> which is purpose-built for it. NCCL is our **throughput** instrument.

---

## 4. What "one-HCA vs all-HCA" actually compares

This is the question you asked: *"one_HCA-vs-all — does that mean it talks with
every GPU in the other server?"* No. **In both runs, all 16 GPUs participate in
the same AllReduce.** The only thing that changes is **how many rails (NICs) NCCL
is allowed to use for the cross-node traffic**, via `NCCL_IB_HCA`:

| Run | `NCCL_IB_HCA` | Cross-node traffic goes over… | Purpose |
|---|---|---|---|
| **one-HCA** | one rail, e.g. `mlx5_0` | a **single** NIC (all GPUs funnel through it) | baseline: one rail's ceiling |
| **all-HCA** | all rails, e.g. `mlx5_0..mlx5_7` | **all 8** NICs in parallel | does the fabric aggregate? |

So it's a **rail-scaling** test, not a GPU-participation test. The comparison
answers one question: **"do N rails give me ~N× the bandwidth of one rail?"**

- **Healthy:** `all-HCA busbw ≈ (number of routing rails) × one-HCA busbw`. That
  means rail aggregation works — each GPU is using its own rail and the leaf/spine
  is spreading the load.
- **Suspicious:** `all-HCA ≈ one-HCA`. Adding rails did nothing → NCCL is really
  only using one rail (bad GID/routing, PXN off, or — as we saw on this fabric —
  only one rail actually routes end to end, so the others were dropped).

> On this fabric, `run_suite.sh --nccl` first pings each launcher↔peer rail pair
> and **restricts `NCCL_IB_HCA` to the rails that routed**. If only one rail
> routes, one-HCA and all-HCA measure the same single rail and the comparison is
> meaningless until more rails route — that's a fabric fix, not a chart fix.

---

## 5. Reading the output table

nccl-tests prints something like (columns trimmed):

```
#   size      count    type   redop    time     algbw    busbw  #wrong    time    algbw   busbw  #wrong
#   (B)       (elem)                   (us)     (GB/s)   (GB/s)         (us)   (GB/s)  (GB/s)
  134217728   33554432  float    sum   1350.2    99.4    186.4     0     1348.0   99.6   186.7     0
  268435456   67108864  float    sum   2680.5   100.1    187.7     0     ...
  ...
# Avg bus bandwidth : 174.32
```

- Two blocks of `time/algbw/busbw`: **out-of-place** then **in-place** (whether the
  result overwrites the input buffer). Both should be similar.
- **`#wrong` must be 0.** Non-zero = data corruption on the wire (a real fabric
  fault — bad cable, PFC misconfig, wrong GID) — the bandwidth number is worthless
  if `#wrong > 0`.
- **`Avg bus bandwidth`** (last line) is the single number the report captures.

The per-size progress lines you now see (`NCCL [1/2] one-HCA progress: k/25 ...`)
are added by our runner so a long sweep isn't a frozen screen; the full raw table
is still saved to `nccl/one_hca.txt` and `nccl/all_hca.txt`.

---

## 6. The environment variables (and the `_CFG` two-layer design)

Every real NCCL variable we set is [documented by NVIDIA](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html).
There are **two layers**, which is why you'll see `*_CFG` names that are *not* in
the NCCL docs:

- **`*_CFG` are OURS**, not NCCL's. The Helm chart renders chart config (which may
  contain placeholders like `auto`) into `NCCL_*_CFG` pod-env vars. NCCL never
  reads these.
- The runner **resolves** them (e.g. turns `auto` into a real GID index) and passes
  only genuine, documented variables to the ranks via **`mpirun -x NAME=value`**.
  `NCCL_IB_GID_INDEX=auto` would make NCCL choke — the `_CFG` indirection is what
  prevents that.

| Real NCCL var (passed via `-x`) | From chart value | What it does |
|---|---|---|
| `NCCL_IB_HCA` | ping-gated rail list | which rails NCCL may use (the one-vs-all knob) |
| `NCCL_IB_GID_INDEX` | `nccl.ib.gidIndex` (`auto`→3) | which GID; must be the **IPv4-mapped RoCE v2** one to route |
| `NCCL_IB_DISABLE` | `nccl.ib.disable` | `0` = use IB/RoCE (never fall back to sockets) |
| `NCCL_SOCKET_IFNAME` | `nccl.ib.socketIfname` | which iface for the TCP **bootstrap** (eth0), not the data |
| `NCCL_IB_TC` | `nccl.ib.tc` (106) | RoCE traffic class → the switch's **lossless/PFC** lane. Wrong value → PFC drops → BW collapses. **Fabric-specific.** |
| `NCCL_IB_QPS_PER_CONNECTION` | `nccl.ib.qpsPerConnection` (16) | multiple queue pairs per peer → more parallel flows → more BW |
| `NCCL_PXN_DISABLE` | `nccl.ib.pxnDisable` (0) | keep **PXN**: a GPU may reach a remote peer via a NVLink-neighbour's rail → better rail utilisation |
| `NCCL_SHM_DISABLE` | `nccl.shm.disable` (0) | keep the intra-node **shared-memory** transport (needs a sized `/dev/shm`) |
| `NCCL_DEBUG` | `nccl.ib.debug` (WARN) | `INFO` prints the transport + GID actually chosen |

`tc=106`, `qps=16`, `pxn=0` are the values that reached ~174 GB/s on this fabric —
they are defaults here, but `tc` especially is switch-dependent (DSCP = `tc>>2` =
26; it must match the PFC lane your network team configured).

---

## 7. Common failure signatures (and where each is fixed)

| Symptom | Meaning | Fix in this chart |
|---|---|---|
| `unhandled system error` (`common.cu` / `all_reduce.cu`) | transport init failed after NCCL loaded | usually `/dev/shm` too small or a bad rail — sized `/dev/shm` + rail gating |
| `No space left on device` | `/dev/shm` (64Mi default) exhausted | memory-backed `/dev/shm` = `nccl.shm.size` (16Gi) |
| `ibv_modify_qp ... errno 19 (No such device)` | NCCL given a non-routing / non-rail HCA | HCA auto-detect from rail netdevs + ping-gated `NCCL_IB_HCA` |
| falls back to `NET/Socket` (slow) | no routable GID or IB disabled | IPv4-mapped GID auto-detect; `NCCL_IB_DISABLE=0` |
| `all-HCA ≈ one-HCA` | rails not aggregating | check routing/PXN/`NCCL_IB_HCA`; verify >1 rail passed the ping check |
| `could not access executable` | nccl-tests not built (image ships **source**) | `nccl_one_vs_many.sh build` on **both** pods first (path is `/opt/nccl-tests`, plural) |
| `#wrong > 0` | data corruption on the wire | fabric fault (cable/PFC/GID) — not a benchmark tuning issue |

---

## 8. TL;DR

- We run a **list of collectives** (`all_reduce`, `alltoall`, `reduce_scatter`,
  `sendrecv`) — each a real traffic pattern; **alltoall** is the rail-crossing
  exposer, **sendrecv** the KV-transfer proxy. One **rank per GPU**, NVLink inside
  a node and **RoCE across** the two nodes.
- **busbw** (not algbw) is the hardware number; compare it to aggregate rail line
  rate.
- The **average** busbw depends entirely on the **size sweep** — `128M..8G` gives
  the saturated ~170 GB/s figure; starting at `8` averages in the latency floor
  and looks like ~11 GB/s. Same fabric.
- **one-HCA vs all-HCA** = *how many rails NCCL may use*, not which GPUs talk. It
  tests **rail aggregation** (want ≈ N× scaling).
- `*_CFG` vars are chart plumbing; only real, documented `NCCL_*` vars reach NCCL
  (via `mpirun -x`).
