# Graph Report - .  (2026-07-11)

## Corpus Check
- Corpus is ~16,290 words - fits in a single context window. You may not need a graph.

## Summary
- 98 nodes · 162 edges · 14 communities (13 shown, 1 thin omitted)
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 6 edges (avg confidence: 0.93)
- Token cost: 91,248 input · 0 output

## Community Hubs (Navigation)
- Chart Architecture & Design Rationale
- Latency Plotting Core
- Perftest Runner (roce_bench.sh)
- NCCL Deep-Dive Concepts
- NCCL Test Runner (nccl_one_vs_many.sh)
- Report Assembly & NCCL Plotting
- NCCL Data Export & Curve Plotting
- Docs & Shared Image Overview
- Topology & Storage Design
- Bandwidth Plotting
- run_suite.sh Orchestrator Core
- Latency Time-Series Plotting
- Helm Pod Templates
- Rail Routing Script

## God Nodes (most connected - your core abstractions)
1. `CLAUDE.md — RoCE benchmark architecture/contributor guide` - 23 edges
2. `main()` - 12 edges
3. `values.yaml — chart configuration (image, topology, scenario, benchmarks, gpudirect, nccl, results, report)` - 10 edges
4. `RoCE-tests-chart/README.md — user quickstart` - 9 edges
5. `export_all_data()` - 7 edges
6. `NCCL-DEEP-DIVE.md — NCCL benchmark deep dive` - 7 edges
7. `_load_samples()` - 6 edges
8. `_nccl_collectives()` - 6 edges
9. `templates/configmap.yaml — glob-mounts files/* as -scripts ConfigMap` - 6 edges
10. `values.nccl — nodes, rails, gpus, collectives, sizes, ib.* tuning for the one-HCA-vs-all test` - 6 edges

## Surprising Connections (you probably didn't know these)
- `IT / AI Infrastructure Benchmarks (repo index)` --references--> `CLAUDE.md — RoCE benchmark architecture/contributor guide`  [EXTRACTED]
  README.md → RoCE-tests-chart/CLAUDE.md
- `IT / AI Infrastructure Benchmarks (repo index)` --references--> `Dockerfile — shared CUDA13+RDMA benchmark image (perftest, NCCL, OpenMPI)`  [EXTRACTED]
  README.md → RoCE-tests-chart/CLAUDE.md
- `IT / AI Infrastructure Benchmarks (repo index)` --references--> `RoCE-tests-chart/README.md — user quickstart`  [EXTRACTED]
  README.md → RoCE-tests-chart/README.md
- `templates/configmap.yaml — glob-mounts files/* as -scripts ConfigMap` --shares_data_with--> `files/nccl_one_vs_many.sh — builds nccl-tests, runs mpirun one-HCA-vs-all per collective`  [INFERRED]
  RoCE-tests-chart/roce-perf/templates/configmap.yaml → RoCE-tests-chart/CLAUDE.md
- `values.nccl — nodes, rails, gpus, collectives, sizes, ib.* tuning for the one-HCA-vs-all test` --conceptually_related_to--> `Collectives swept one-HCA-vs-all: all_reduce_perf, alltoall_perf, reduce_scatter_perf, sendrecv_perf — each a distinct traffic pattern`  [INFERRED]
  RoCE-tests-chart/roce-perf/values.yaml → RoCE-tests-chart/NCCL-DEEP-DIVE.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **RoCE-perf subject documentation triad (CLAUDE.md, README.md, NCCL-DEEP-DIVE.md) cross-reference each other as one architecture+usage+deep-dive doc set** — roce_tests_chart_claude, roce_tests_chart_readme, roce_tests_chart_nccl_deep_dive [INFERRED 0.85]
- **Templates sharing the roce-perf.* Helm helper functions (env/container/volumes/labels) so pod shape changes happen in one place** — roce_tests_chart_roce_perf_templates_pods, roce_tests_chart_roce_perf_templates_nccl_pods, roce_tests_chart_roce_perf_templates_configmap, roce_tests_chart_roce_perf_templates_report_job, roce_tests_chart_roce_perf_templates_helpers_tpl [EXTRACTED 1.00]
- **NCCL one-vs-many execution flow: run_suite.sh drives rail_routes.sh (source routing) and nccl_one_vs_many.sh (mpirun sweep) against the nccl-pods, configured by values.nccl** — roce_tests_chart_run_suite_sh, roce_tests_chart_roce_perf_files_rail_routes_sh, roce_tests_chart_roce_perf_files_nccl_one_vs_many_sh, roce_tests_chart_roce_perf_templates_nccl_pods, roce_tests_chart_roce_perf_values_nccl [INFERRED 0.85]

## Communities (14 total, 1 thin omitted)

### Community 0 - "Chart Architecture & Design Rationale"
Cohesion: 0.25
Nodes (11): CLAUDE.md — RoCE benchmark architecture/contributor guide, build_test_plan invariant: server and client independently derive identical port-per-(test,size) assignment from the same env, no negotiation needed, NUMA pinning: numactl wraps perftest per rail's NIC numa_node, best-effort unless pod is Guaranteed QoS + topology manager single-numa-node, One VF per pod convention: device-plugin resource + NAD derived per-pod from the nic, Per-rail source routing: multi-VF pods need one routing table + ip rule per rail-IP to avoid rp_filter drops, roce-perf Helm chart (Chart.yaml), files/plot_report.py — report/plotting script (BW bars, latency CDF/histogram, NCCL bars), files/rail_routes.sh — per-rail source routing (ip rule from <rail-ip>, loose rp_filter) (+3 more)

### Community 1 - "Latency Plotting Core"
Cohesion: 0.29
Nodes (9): _isnum(), _load_samples(), _numeric_from_raw(), plot_lat_cdf(), plot_lat_hist(), CDF overlay of raw -U samples -> tail-latency comparison across envs., Re-parse raw perftest stdout: keep 1-2-field all-numeric lines' last field., Raw -U samples as a 1-D array, or None. Try the filtered .unsorted.txt     first (+1 more)

### Community 2 - "Perftest Runner (roce_bench.sh)"
Cohesion: 0.31
Nodes (6): add_bw_test(), add_lat_test(), banner(), build_test_plan(), roce_bench.sh script, summarize_latency()

### Community 3 - "NCCL Deep-Dive Concepts"
Cohesion: 0.25
Nodes (9): Memory-backed /dev/shm (default 8-16Gi) on NCCL pods to avoid k8s default 64Mi 'No space left on device', IPv4-mapped RoCE v2 GID (::ffff:<rail-ip>, typically index 3) required for cross-leaf routing; link-local GIDs don't route, NCCL-DEEP-DIVE.md — NCCL benchmark deep dive, algbw vs busbw: busbw = algbw x 2(n-1)/n corrects for AllReduce's multi-hop wire traffic; busbw is the hardware-comparable number, *_CFG two-layer env design: chart renders NCCL_*_CFG placeholders (e.g. 'auto'), runner resolves them into real documented NCCL_* vars passed via mpirun -x, Collectives swept one-HCA-vs-all: all_reduce_perf, alltoall_perf, reduce_scatter_perf, sendrecv_perf — each a distinct traffic pattern, one-HCA-vs-all: rail-scaling test via NCCL_IB_HCA (1 rail vs all rails), not a GPU-participation test; expects ~N x scaling, files/nccl_one_vs_many.sh — builds nccl-tests, runs mpirun one-HCA-vs-all per collective (+1 more)

### Community 4 - "NCCL Test Runner (nccl_one_vs_many.sh)"
Cohesion: 0.28
Nodes (3): build_nccl_tests(), run_nccl(), nccl_one_vs_many.sh script

### Community 5 - "Report Assembly & NCCL Plotting"
Cohesion: 0.22
Nodes (9): discover_runs(), html_escape(), load_lat_json(), main(), plot_nccl(), -> list of (label, {percentiles}) for the table., Grouped busbw bar: x = collective, one-HCA vs all-HCA (per env)., Latest run dir per env-label (dirname sorts ascending by timestamp). (+1 more)

### Community 6 - "NCCL Data Export & Curve Plotting"
Cohesion: 0.28
Nodes (9): export_all_data(), _load_json(), _nccl_collectives(), parse_nccl_table(), plot_nccl_curves(), {collective: {"one": {...}, "all": {...}}} from a run's nccl/nccl.json., Parse an nccl-tests stdout table -> [{size, algbw, busbw}] per message size., Per-collective busbw-vs-size (one dashed / all solid) PLUS a cross-collective (+1 more)

### Community 7 - "Docs & Shared Image Overview"
Cohesion: 0.47
Nodes (6): IT / AI Infrastructure Benchmarks (repo index), Subject Folder Convention: README.md (usage) + CLAUDE.md (architecture) per subject, reusing the shared CUDA image, Dockerfile — shared CUDA13+RDMA benchmark image (perftest, NCCL, OpenMPI), RoCE-tests-chart/README.md — user quickstart, templates/NOTES.txt — post-install manual-steps notes, run_suite.sh — host-side oc-based driver script (IP discovery, launches clients, --report, --nccl)

### Community 8 - "Topology & Storage Design"
Cohesion: 0.40
Nodes (5): Leaf/spine = which NIC an endpoint uses (8 rails/node, first 4 leaf1, next 4 leaf2), Results storage precedence: pvcName (shared RWX) > hostPath (node-local, default) > emptyDir; run_suite.sh --report gathers node-local results so no shared PVC is needed except for the in-cluster report Job, values.yaml — chart configuration (image, topology, scenario, benchmarks, gpudirect, nccl, results, report), values.benchmarks — bw.{read,write} and lat.{write,read,send} perftest matrix config, values.scenario — server/sameLeaf/spine endpoint topology (node, nic, nad, gpuIndex)

### Community 9 - "Bandwidth Plotting"
Cohesion: 0.40
Nodes (5): human_size(), plot_bw(), -> {size_bytes: bw_avg_gbps}., Grouped bar: x = message size, group = environment., read_bw_csv()

### Community 10 - "run_suite.sh Orchestrator Core"
Cohesion: 0.70
Nodes (4): log(), oc_exec(), run_suite.sh script, usage()

### Community 11 - "Latency Time-Series Plotting"
Cohesion: 0.50
Nodes (4): _peak_downsample(), plot_lat_timeseries(), Downsample to ~target points while KEEPING spikes (max within each bin)., Latency vs sample index (proxy for time) -> see spikes/jitter over the run.

### Community 12 - "Helm Pod Templates"
Cohesion: 0.67
Nodes (4): templates/_helpers.tpl — roce-perf.env / roce-perf.container / roce-perf.volumes shared helpers, templates/nccl-pods.yaml — nccl-launcher/nccl-peer multi-rail pods, templates/pods.yaml — rdma-server/rdma-client-leaf/rdma-client-spine pods, values.topology — nadPattern/resourcePattern/device fallback templates

## Knowledge Gaps
- **4 isolated node(s):** `rail_routes.sh script`, `roce-perf Helm chart (Chart.yaml)`, `algbw vs busbw: busbw = algbw x 2(n-1)/n corrects for AllReduce's multi-hop wire traffic; busbw is the hardware-comparable number`, `values.benchmarks — bw.{read,write} and lat.{write,read,send} perftest matrix config`
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `CLAUDE.md — RoCE benchmark architecture/contributor guide` connect `Chart Architecture & Design Rationale` to `Topology & Storage Design`, `NCCL Deep-Dive Concepts`, `Helm Pod Templates`, `Docs & Shared Image Overview`?**
  _High betweenness centrality (0.066) - this node is a cross-community bridge._
- **Why does `NCCL-DEEP-DIVE.md — NCCL benchmark deep dive` connect `NCCL Deep-Dive Concepts` to `Topology & Storage Design`, `Docs & Shared Image Overview`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Why does `values.yaml — chart configuration (image, topology, scenario, benchmarks, gpudirect, nccl, results, report)` connect `Topology & Storage Design` to `Chart Architecture & Design Rationale`, `NCCL Deep-Dive Concepts`, `Helm Pod Templates`, `Docs & Shared Image Overview`?**
  _High betweenness centrality (0.021) - this node is a cross-community bridge._
- **What connects `Latest run dir per env-label (dirname sorts ascending by timestamp).`, `-> {size_bytes: bw_avg_gbps}.`, `Grouped bar: x = message size, group = environment.` to the rest of the system?**
  _25 weakly-connected nodes found - possible documentation gaps or missing edges._