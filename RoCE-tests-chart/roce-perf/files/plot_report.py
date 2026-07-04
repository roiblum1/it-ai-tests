#!/usr/bin/env python3
"""
roce-perf report generator.

Scans the results PVC for run directories produced by roce_bench.sh
(<env-label>-<timestamp>/ with setup.json), then emits comparison graphs +
a self-contained report.html into <results>/<output-subdir>.

  plot_report.py <results_dir> [output_subdir]

Graphs:
  - BW grouped bars (avg Gb/s) per test, one bar group per environment/size.
  - Latency over time per test: raw -U samples vs sample order (peak-preserving
    downsample) -> spikes/jitter visible.
  - Latency CDF overlay per test (sorts the raw -U samples) -> tail comparison.
  - Latency histogram per test (log-y) -> distribution.
  - Latency percentile table from each run's <test>.json.
  - GPUDirect charts when a gpudirect/ subtree exists.
  - NCCL one-HCA-vs-all bar when nccl/nccl.json exists.

Only stdlib + numpy + matplotlib (Agg) are required.
"""
import csv
import glob
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

BW_TESTS = ["read_bw", "write_bw"]
LAT_TESTS = ["write_lat", "read_lat", "send_lat"]
SUBTREES = ["", "gpudirect"]  # "" = NIC/host memory, gpudirect = --use_cuda


def discover_runs(results_dir, out_dir_name):
    """Latest run dir per env-label (dirname sorts ascending by timestamp)."""
    by_label = {}
    for name in sorted(os.listdir(results_dir)):
        path = os.path.join(results_dir, name)
        setup = os.path.join(path, "setup.json")
        if name == out_dir_name or not os.path.isdir(path) or not os.path.exists(setup):
            continue
        try:
            with open(setup) as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            continue
        label = meta.get("env_label", name)
        by_label[label] = {"name": name, "label": label, "path": path, "setup": meta}
    return [by_label[k] for k in sorted(by_label)]


def read_bw_csv(path):
    """-> {size_bytes: bw_avg_gbps}."""
    out = {}
    try:
        with open(path) as fh:
            for row in csv.DictReader(fh):
                try:
                    out[int(row["size_bytes"])] = float(row["bw_avg_gbps"])
                except (ValueError, KeyError):
                    pass
    except OSError:
        return {}
    return out


def plot_bw(runs, test, subtree, out_dir):
    """Grouped bar: x = message size, group = environment."""
    series = {}  # label -> {size: gbps}
    for r in runs:
        sub = (subtree + "/") if subtree else ""
        data = read_bw_csv(os.path.join(r["path"], sub + "bw", test + ".csv"))
        if data:
            series[r["label"]] = data
    if not series:
        return None

    sizes = sorted({s for d in series.values() for s in d})
    labels = list(series)
    x = np.arange(len(sizes))
    width = 0.8 / max(len(labels), 1)

    plt.figure(figsize=(8, 4.5))
    for i, lab in enumerate(labels):
        vals = [series[lab].get(s, 0) for s in sizes]
        plt.bar(x + i * width, vals, width, label=lab)
    plt.xticks(x + width * (len(labels) - 1) / 2, [human_size(s) for s in sizes])
    tag = " (GPUDirect)" if subtree else ""
    plt.title(f"{test} average bandwidth{tag}")
    plt.ylabel("Gb/s"); plt.xlabel("message size"); plt.legend(); plt.grid(axis="y", alpha=0.3)
    fname = f"bw_{subtree or 'nic'}_{test}.png"
    plt.tight_layout(); plt.savefig(os.path.join(out_dir, fname), dpi=110); plt.close()
    return fname


def plot_lat_cdf(runs, test, subtree, out_dir):
    """CDF overlay of raw -U samples -> tail-latency comparison across envs."""
    plotted = False
    plt.figure(figsize=(8, 4.5))
    for r in runs:
        sub = (subtree + "/") if subtree else ""
        f = os.path.join(r["path"], sub + "lat", test + ".unsorted.txt")
        if not os.path.exists(f) or os.path.getsize(f) == 0:
            continue
        try:
            samples = np.loadtxt(f)
        except ValueError:
            continue
        samples = np.sort(np.atleast_1d(samples))
        if samples.size == 0:
            continue
        cdf = np.linspace(0, 1, samples.size, endpoint=True)
        plt.plot(samples, cdf, label=r["label"])
        plotted = True
    if not plotted:
        plt.close(); return None
    tag = " (GPUDirect)" if subtree else ""
    plt.title(f"{test} latency CDF{tag}")
    plt.xlabel("latency (usec)"); plt.ylabel("cumulative fraction")
    plt.ylim(0, 1); plt.legend(); plt.grid(alpha=0.3)
    fname = f"latcdf_{subtree or 'nic'}_{test}.png"
    plt.tight_layout(); plt.savefig(os.path.join(out_dir, fname), dpi=110); plt.close()
    return fname


def _load_samples(path):
    """Raw -U samples as a 1-D array, or None if missing/empty/unparseable."""
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return None
    try:
        s = np.atleast_1d(np.loadtxt(path))
    except ValueError:
        return None
    return s if s.size else None


def _peak_downsample(y, target=5000):
    """Downsample to ~target points while KEEPING spikes (max within each bin)."""
    n = y.size
    if n <= target:
        return np.arange(n), y
    edges = np.linspace(0, n, target + 1, dtype=int)
    xs, ys = [], []
    for a, b in zip(edges[:-1], edges[1:]):
        if b <= a:
            continue
        j = int(np.argmax(y[a:b]))
        xs.append(a + j)
        ys.append(y[a + j])
    return np.array(xs), np.array(ys)


def plot_lat_timeseries(runs, test, subtree, out_dir):
    """Latency vs sample index (proxy for time) -> see spikes/jitter over the run."""
    plotted = False
    plt.figure(figsize=(9, 4))
    for r in runs:
        sub = (subtree + "/") if subtree else ""
        s = _load_samples(os.path.join(r["path"], sub + "lat", test + ".unsorted.txt"))
        if s is None:
            continue
        x, y = _peak_downsample(s)
        plt.plot(x, y, linewidth=0.6, label=r["label"], rasterized=True)
        plotted = True
    if not plotted:
        plt.close(); return None
    tag = " (GPUDirect)" if subtree else ""
    plt.title(f"{test} latency over time{tag}  (peaks preserved)")
    plt.xlabel("sample # (in order)"); plt.ylabel("latency (usec)")
    plt.legend(); plt.grid(alpha=0.3)
    fname = f"lattime_{subtree or 'nic'}_{test}.png"
    plt.tight_layout(); plt.savefig(os.path.join(out_dir, fname), dpi=110); plt.close()
    return fname


def plot_lat_hist(runs, test, subtree, out_dir):
    """Histogram of the -U sample distribution (log-y so the tail is visible)."""
    data = []
    for r in runs:
        sub = (subtree + "/") if subtree else ""
        s = _load_samples(os.path.join(r["path"], sub + "lat", test + ".unsorted.txt"))
        if s is not None:
            data.append((r["label"], s))
    if not data:
        return None
    lo = min(float(s.min()) for _, s in data)
    hi = max(float(np.percentile(s, 99.9)) for _, s in data)
    if hi <= lo:
        hi = lo + 1.0
    bins = np.linspace(lo, hi, 60)
    plt.figure(figsize=(8, 4))
    for lab, s in data:
        plt.hist(s, bins=bins, histtype="step", log=True, label=lab)
    tag = " (GPUDirect)" if subtree else ""
    plt.title(f"{test} latency histogram{tag}")
    plt.xlabel("latency (usec)"); plt.ylabel("count (log)")
    plt.legend(); plt.grid(alpha=0.3)
    fname = f"lathist_{subtree or 'nic'}_{test}.png"
    plt.tight_layout(); plt.savefig(os.path.join(out_dir, fname), dpi=110); plt.close()
    return fname


def load_lat_json(runs, test, subtree):
    """-> list of (label, {percentiles}) for the table."""
    rows = []
    for r in runs:
        sub = (subtree + "/") if subtree else ""
        f = os.path.join(r["path"], sub + "lat", test + ".json")
        if os.path.exists(f):
            try:
                with open(f) as fh:
                    rows.append((r["label"], json.load(fh)))
            except (OSError, ValueError):
                pass
    return rows


def plot_nccl(runs, out_dir):
    """one-HCA-vs-all busbw bar, per run that has nccl/nccl.json."""
    bars = []  # (label, one, all)
    for r in runs:
        f = os.path.join(r["path"], "nccl", "nccl.json")
        if not os.path.exists(f):
            continue
        try:
            with open(f) as fh:
                d = json.load(fh)
            bars.append((r["label"], d["one"]["busbw"], d["all"]["busbw"]))
        except (OSError, ValueError, KeyError):
            pass
    if not bars:
        return None
    labels = [b[0] for b in bars]
    x = np.arange(len(labels))
    plt.figure(figsize=(7, 4.5))
    plt.bar(x - 0.2, [b[1] for b in bars], 0.4, label="one HCA")
    plt.bar(x + 0.2, [b[2] for b in bars], 0.4, label="all HCAs")
    plt.xticks(x, labels)
    plt.title("NCCL all_reduce busbw: one HCA vs all")
    plt.ylabel("busbw (GB/s)"); plt.legend(); plt.grid(axis="y", alpha=0.3)
    fname = "nccl_one_vs_all.png"
    plt.tight_layout(); plt.savefig(os.path.join(out_dir, fname), dpi=110); plt.close()
    return fname


def human_size(n):
    for unit in ("B", "K", "M", "G"):
        if n < 1024:
            return f"{n}{unit}"
        n //= 1024
    return f"{n}T"


def html_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: plot_report.py <results_dir> [output_subdir]")
    results_dir = sys.argv[1]
    out_name = sys.argv[2] if len(sys.argv) > 2 else "report"
    out_dir = os.path.join(results_dir, out_name)
    os.makedirs(out_dir, exist_ok=True)

    runs = discover_runs(results_dir, out_name)
    if not runs:
        sys.exit(f"no run directories with setup.json found under {results_dir}")
    print(f"found {len(runs)} environment(s): {', '.join(r['label'] for r in runs)}")

    html = ["<html><head><meta charset='utf-8'><title>roce-perf report</title>",
            "<style>body{font-family:sans-serif;margin:2rem;max-width:1000px}"
            "table{border-collapse:collapse;margin:1rem 0}td,th{border:1px solid #ccc;padding:4px 8px}"
            "img{max-width:100%;border:1px solid #eee;margin:0.5rem 0}h2{margin-top:2rem}</style></head><body>",
            "<h1>roce-perf benchmark report</h1>"]

    # ---- setup summary table -------------------------------------------------
    html.append("<h2>Setup summary</h2><table><tr>"
                "<th>environment</th><th>device</th><th>node</th><th>mtu</th>"
                "<th>gpudirect</th><th>date</th><th>run dir</th></tr>")
    for r in runs:
        m = r["setup"]
        html.append("<tr>" + "".join(f"<td>{html_escape(v)}</td>" for v in (
            m.get("env_label"), m.get("device"), m.get("node"), m.get("mtu"),
            m.get("gpudirect"), m.get("date"), r["name"])) + "</tr>")
    html.append("</table>")

    has_gpu = any(os.path.isdir(os.path.join(r["path"], "gpudirect")) for r in runs)

    for subtree in SUBTREES:
        if subtree and not has_gpu:
            continue
        section = "GPUDirect (--use_cuda)" if subtree else "NIC (host memory)"
        html.append(f"<h2>{section}</h2>")

        html.append("<h3>Bandwidth</h3>")
        for test in BW_TESTS:
            img = plot_bw(runs, test, subtree, out_dir)
            if img:
                html.append(f"<img src='{img}' alt='{test}'>")

        html.append("<h3>Latency (over-time peaks, CDF, histogram, percentiles)</h3>")
        for test in LAT_TESTS:
            for img in (plot_lat_timeseries(runs, test, subtree, out_dir),
                        plot_lat_cdf(runs, test, subtree, out_dir),
                        plot_lat_hist(runs, test, subtree, out_dir)):
                if img:
                    html.append(f"<img src='{img}' alt='{test}'>")
            rows = load_lat_json(runs, test, subtree)
            if rows:
                html.append(f"<p><b>{test}</b> (usec)</p><table><tr><th>env</th>"
                            "<th>min</th><th>avg</th><th>p50</th><th>p99</th><th>p99.9</th><th>max</th></tr>")
                for lab, d in rows:
                    html.append("<tr>" + f"<td>{html_escape(lab)}</td>" + "".join(
                        f"<td>{html_escape(d.get(k, 'NA'))}</td>"
                        for k in ("min", "avg", "p50", "p99", "p999", "max")) + "</tr>")
                html.append("</table>")

    # ---- NCCL ----------------------------------------------------------------
    nccl_img = plot_nccl(runs, out_dir)
    if nccl_img:
        html.append("<h2>NCCL one-HCA-vs-all</h2>")
        html.append(f"<img src='{nccl_img}' alt='nccl'>")

    html.append("</body></html>")
    report = os.path.join(out_dir, "report.html")
    with open(report, "w") as fh:
        fh.write("\n".join(html))
    print(f"wrote {report}")


if __name__ == "__main__":
    main()
