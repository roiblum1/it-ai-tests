# IT / AI Infrastructure Benchmarks

A collection of benchmark suites for validating AI-datacenter infrastructure on
OpenShift. The repo is organized **by subject**: each subject is a self-contained
folder with its own `README.md` (how to use it) and `CLAUDE.md` (architecture /
contributor guide).

## Subjects

| Subject | Path | What it measures |
|---|---|---|
| RoCE leaf/spine RDMA | [RoCE-tests-chart/](RoCE-tests-chart/) | RDMA bandwidth & latency on a Port2Port SR-IOV fabric — **same-leaf vs spine-crossing**, optionally over GPUDirect, plus an NCCL one-HCA-vs-all test, rendered into comparison graphs. |

> More subjects are added as sibling folders, each following the same
> `README.md` + `CLAUDE.md` convention.

## Shared / global components

- **CUDA benchmark image** — [RoCE-tests-chart/Dockerfile](RoCE-tests-chart/Dockerfile).
  One NVIDIA CUDA + RDMA image (perftest plain & CUDA, NCCL, OpenMPI, and a full
  network/RDMA diagnostics toolset). It is the shared image every benchmark pod
  uses; build/push it once and reference it from a subject's chart:

  ```bash
  docker build -t <registry>/it-ai-rdma-perf:v1 RoCE-tests-chart/
  docker push  <registry>/it-ai-rdma-perf:v1
  ```

## Repo layout

```
.
├── README.md                 # this file — the subject index
└── RoCE-tests-chart/         # subject: RoCE leaf/spine RDMA benchmark
    ├── README.md             #   how to run it
    ├── CLAUDE.md             #   architecture / contributor guide
    ├── Dockerfile            #   the shared CUDA benchmark image
    ├── run_suite.sh          #   host-side driver (oc-based)
    └── roce-perf/            #   the Helm chart
```

## Adding a subject

1. Create a new top-level folder (e.g. `nccl-scale/`).
2. Add a `README.md` (usage) and `CLAUDE.md` (architecture) to it.
3. Reuse the shared CUDA image where possible.
4. Add a row to the **Subjects** table above.
