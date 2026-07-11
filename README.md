# IT / AI Infrastructure Benchmarks

A collection of benchmark suites for validating AI-datacenter infrastructure on
OpenShift. The repo is organized **by subject**: each subject is a self-contained
folder with its own `README.md` (how to use it) and `CLAUDE.md` (architecture /
contributor guide). The pieces shared across subjects live at the **repo root**:
the [Dockerfile](Dockerfile) (one image every pod uses) and [run_suite.sh](run_suite.sh)
(one entry point that dispatches to a subject's driver).

## Subjects

| Subject | Path | What it measures |
|---|---|---|
| RoCE leaf/spine RDMA | [RoCE-tests-chart/](RoCE-tests-chart/) | RDMA bandwidth & latency on a Port2Port SR-IOV fabric — **same-leaf vs spine-crossing**, optionally over GPUDirect, plus an NCCL one-HCA-vs-all test, rendered into comparison graphs. |
| Node perf tuning | [node-perf/](node-perf/) | Node CPU (sysbench), memory (sysbench), and disk (fio) benchmarks — **baseline vs tuned** comparison with a per-metric Δ%, so you can see the effect of a tuning change (governor, hugepages, `tuned`, NUMA, kernel cmdline). |

Current scope is the **1-to-1** server↔client flow (basic RDMA bandwidth/latency,
GPUDirect, NCCL one-vs-many). Many-to-many and tail-latency-under-load are planned
but not yet built.

> More subjects are added as sibling folders, each following the same
> `README.md` + `CLAUDE.md` convention.

## Shared / global components

- **Benchmark image** — [Dockerfile](Dockerfile) at the repo root. One NVIDIA
  CUDA/RDMA image (perftest plain & CUDA, NCCL, OpenMPI, a full network/RDMA
  diagnostics toolset, **plus `sysbench` and `fio` for the node-perf subject**). It is
  the shared image every benchmark pod uses; build/push it once from the repo root
  and reference it from a subject's chart:

  ```bash
  docker build -t <registry>/it-ai-rdma-perf:v3 .
  docker push  <registry>/it-ai-rdma-perf:v3
  ```

  Both subjects point at this image (`node-perf` needs the `sysbench`/`fio` it now
  carries), so rebuild + push the `:v3` tag before running node-perf.

- **Driver entry point** — [run_suite.sh](run_suite.sh) at the repo root. A thin
  dispatcher: `./run_suite.sh <subject> [args…]` forwards to the chosen subject's own
  driver (the flows differ per subject, so each keeps its own `run_suite.sh`):

  ```bash
  ./run_suite.sh node-perf -n <ns> --label baseline --report
  ./run_suite.sh roce      -n <ns> --nccl --report
  ```

## Repo layout

```
.
├── README.md                 # this file — the subject index
├── Dockerfile                # SHARED image (CUDA + RDMA + NCCL + sysbench/fio)
├── run_suite.sh              # SHARED entry point -> dispatches to a subject driver
├── RoCE-tests-chart/         # subject: RoCE leaf/spine RDMA benchmark
│   ├── README.md             #   how to run it
│   ├── CLAUDE.md             #   architecture / contributor guide
│   ├── run_suite.sh          #   subject driver (oc-based)
│   └── roce-perf/            #   the Helm chart
└── node-perf/                # subject: node CPU/memory/disk tuning benchmark
    ├── README.md             #   how to run it
    ├── CLAUDE.md             #   architecture / contributor guide
    ├── run_suite.sh          #   subject driver (oc-based)
    └── node-perf/            #   the Helm chart
```

## Adding a subject

1. Create a new top-level folder (e.g. `nccl-scale/`).
2. Add a `README.md` (usage) and `CLAUDE.md` (architecture) to it.
3. Reuse the shared CUDA image where possible.
4. Add a row to the **Subjects** table above.
