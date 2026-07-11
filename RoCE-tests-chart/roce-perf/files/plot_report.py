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

# Self-contained, theme-aware stylesheet for the report (no external fonts/CSS --
# the in-cluster/offline report must render with zero network). Instrument-panel
# palette: cool slate neutrals + one teal accent, monospace for the numbers.
REPORT_CSS = """<style>
:root{
  --bg:#f5f7f9; --surface:#ffffff; --ink:#16202e; --muted:#5a6675;
  --hair:#e3e8ef; --accent:#0e7490; --accent-ink:#0b5566; --warn:#b4530f;
  --zebra:#f8fafb; --shadow:0 1px 2px rgba(16,32,48,.06),0 1px 12px rgba(16,32,48,.04);
  --sans:ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0d1117; --surface:#161b22; --ink:#e6edf3; --muted:#93a1b1;
  --hair:#232c38; --accent:#38bdf8; --accent-ink:#7dd3fc; --warn:#f0883e;
  --zebra:#1a212b; --shadow:0 1px 2px rgba(0,0,0,.4);
}}
:root[data-theme="dark"]{
  --bg:#0d1117; --surface:#161b22; --ink:#e6edf3; --muted:#93a1b1;
  --hair:#232c38; --accent:#38bdf8; --accent-ink:#7dd3fc; --warn:#f0883e;
  --zebra:#1a212b; --shadow:0 1px 2px rgba(0,0,0,.4);
}
:root[data-theme="light"]{
  --bg:#f5f7f9; --surface:#ffffff; --ink:#16202e; --muted:#5a6675;
  --hair:#e3e8ef; --accent:#0e7490; --accent-ink:#0b5566; --warn:#b4530f;
  --zebra:#f8fafb; --shadow:0 1px 2px rgba(16,32,48,.06),0 1px 12px rgba(16,32,48,.04);
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);
  line-height:1.55;-webkit-font-smoothing:antialiased}
.wrap{max-width:1040px;margin:0 auto;padding:3rem 1.5rem 5rem}
header{border-bottom:1px solid var(--hair);padding-bottom:1.75rem;margin-bottom:.5rem}
.eyebrow{font-family:var(--mono);text-transform:uppercase;letter-spacing:.14em;
  font-size:.72rem;color:var(--accent-ink);margin:0 0 .6rem}
h1{font-size:2.1rem;line-height:1.1;margin:0;text-wrap:balance;letter-spacing:-.02em}
.lede{color:var(--muted);max-width:64ch;margin:.85rem 0 0;font-size:1.02rem}
h2{font-size:1.28rem;margin:2.75rem 0 .35rem;letter-spacing:-.01em;
  padding-top:1.5rem;border-top:1px solid var(--hair)}
h3{font-size:.82rem;font-family:var(--mono);text-transform:uppercase;
  letter-spacing:.1em;color:var(--muted);margin:1.75rem 0 .5rem;font-weight:600}
p{margin:.4rem 0}
code{font-family:var(--mono);font-size:.88em;background:var(--zebra);
  padding:.08em .35em;border-radius:4px;border:1px solid var(--hair)}
a{color:var(--accent-ink);text-underline-offset:2px}
img{display:block;width:100%;height:auto;margin:.75rem 0;border:1px solid var(--hair);
  border-radius:10px;background:var(--surface);box-shadow:var(--shadow)}
.tablewrap{overflow-x:auto;margin:.6rem 0 1.1rem}
table{border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:.9rem;
  min-width:100%;background:var(--surface);border:1px solid var(--hair);border-radius:10px}
th,td{padding:.5rem .8rem;text-align:right;border-bottom:1px solid var(--hair);white-space:nowrap}
th:first-child,td:first-child{text-align:left}
thead th,tr:first-child th{color:var(--muted);font-weight:600;font-family:var(--mono);
  font-size:.76rem;text-transform:uppercase;letter-spacing:.05em}
tbody tr:nth-child(even),tr:nth-child(even){background:var(--zebra)}
ul{padding-left:1.1rem;color:var(--muted)}
li{margin:.15rem 0}
li a{font-family:var(--mono);font-size:.9rem}
</style>"""


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
        s = _load_samples(os.path.join(r["path"], sub + "lat", test + ".unsorted.txt"))
        if s is None:
            continue
        samples = np.sort(s)
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


def _isnum(tok):
    try:
        float(tok)
        return True
    except ValueError:
        return False


def _numeric_from_raw(path):
    """Re-parse raw perftest stdout: keep 1-2-field all-numeric lines' last field.
    Same filter roce_bench.sh applies, so we recover samples even if the in-pod
    filter ran with an older build / different -U format."""
    vals = []
    try:
        with open(path) as fh:
            for line in fh:
                toks = line.split()
                if 1 <= len(toks) <= 2 and all(_isnum(t) for t in toks):
                    vals.append(float(toks[-1]))
    except OSError:
        return None
    return np.array(vals) if vals else None


def _load_samples(path):
    """Raw -U samples as a 1-D array, or None. Try the filtered .unsorted.txt
    first, then fall back to re-parsing the sibling .raw.txt (full stdout)."""
    if os.path.exists(path) and os.path.getsize(path) > 0:
        try:
            s = np.atleast_1d(np.loadtxt(path))
            if s.size > 1:
                return s
        except ValueError:
            pass
    if path.endswith(".unsorted.txt"):
        raw = path[: -len(".unsorted.txt")] + ".raw.txt"
        if os.path.exists(raw):
            s = _numeric_from_raw(raw)
            if s is not None and s.size:
                return s
    return None


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


def _nccl_collectives(run):
    """{collective: {"one": {...}, "all": {...}}} from a run's nccl/nccl.json."""
    d = _load_json(os.path.join(run["path"], "nccl", "nccl.json"))
    return d.get("collectives", {}) if d else {}


def plot_nccl(runs, out_dir):
    """Grouped busbw bar: x = collective, one-HCA vs all-HCA (per env)."""
    envs = [r for r in runs if _nccl_collectives(r)]
    multi = len(envs) > 1
    rows = []  # (label, one, all)
    for r in envs:
        for name, d in _nccl_collectives(r).items():
            try:
                one, allv = float(d["one"]["busbw"]), float(d["all"]["busbw"])
            except (KeyError, TypeError, ValueError):
                continue
            short = name.replace("_perf", "")
            rows.append((f"{r['label']}·{short}" if multi else short, one, allv))
    if not rows:
        return None
    labels = [b[0] for b in rows]
    x = np.arange(len(labels)); w = 0.4
    plt.figure(figsize=(max(7, len(labels) * 1.4), 4.6))
    plt.bar(x - w / 2, [b[1] for b in rows], w, label="one HCA")
    plt.bar(x + w / 2, [b[2] for b in rows], w, label="all HCAs")
    plt.xticks(x, labels, rotation=15, ha="right")
    plt.title("NCCL busbw: one HCA vs all, per collective")
    plt.ylabel("busbw (GB/s)"); plt.legend(); plt.grid(axis="y", alpha=0.3)
    fname = "nccl_one_vs_all.png"
    plt.tight_layout(); plt.savefig(os.path.join(out_dir, fname), dpi=110); plt.close()
    return fname


def parse_nccl_table(path):
    """Parse an nccl-tests stdout table -> [{size, algbw, busbw}] per message size.
    The last 8 columns are always [time algbw busbw #wrong] x2 (out-of-place then
    in-place), regardless of the collective's leading columns (redop/root), so the
    out-of-place busbw is at len-6 and algbw at len-7. We report out-of-place."""
    rows = []
    if not os.path.exists(path):
        return rows
    try:
        with open(path) as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                f = s.split()
                if len(f) < 8 or not f[0].isdigit():
                    continue
                try:
                    rows.append({"size": int(f[0]),
                                 "algbw": float(f[len(f) - 7]),
                                 "busbw": float(f[len(f) - 6])})
                except (ValueError, IndexError):
                    continue
    except OSError:
        return []
    return rows


def plot_nccl_curves(runs, out_dir):
    """Per-collective busbw-vs-size (one dashed / all solid) PLUS a cross-collective
    all-HCA comparison. Returns [(caption, fname), ...]. Files now live under
    nccl/<collective>/{one_hca,all_hca}.txt."""
    from collections import OrderedDict
    data = OrderedDict()  # collective -> [(env, mode, sizes, busbw)]
    for r in runs:
        for coll in _nccl_collectives(r):
            for mode, fn in (("one-HCA", "one_hca.txt"), ("all-HCA", "all_hca.txt")):
                rows = parse_nccl_table(os.path.join(r["path"], "nccl", coll, fn))
                if rows:
                    data.setdefault(coll, []).append(
                        (r["label"], mode, [x["size"] for x in rows], [x["busbw"] for x in rows]))
    if not data:
        return []
    multi_env = len([r for r in runs if _nccl_collectives(r)]) > 1
    imgs = []

    # Cross-collective comparison (all-HCA) -- the "which collective is fastest" view.
    plt.figure(figsize=(9, 5)); any_ = False
    for coll, series in data.items():
        for env, mode, sizes, busbw in series:
            if mode == "all-HCA":
                lab = coll.replace("_perf", "") + (f" ({env})" if multi_env else "")
                plt.plot(sizes, busbw, marker="o", ms=3, label=lab); any_ = True
    if any_:
        plt.xscale("log", base=2)
        plt.title("all-HCA busbw vs size — collectives compared")
        plt.xlabel("message size (bytes)"); plt.ylabel("busbw (GB/s)")
        plt.legend(fontsize=8); plt.grid(alpha=0.3)
        fn = "nccl_compare_allhca.png"; plt.tight_layout()
        plt.savefig(os.path.join(out_dir, fn), dpi=110); plt.close()
        imgs.append(("Collectives compared (all-HCA busbw vs size)", fn))
    else:
        plt.close()

    # Per-collective one-HCA vs all-HCA (rail aggregation for that pattern).
    for coll, series in data.items():
        plt.figure(figsize=(9, 5))
        for env, mode, sizes, busbw in series:
            lab = (f"{env} " if multi_env else "") + mode
            plt.plot(sizes, busbw, "--" if mode == "one-HCA" else "-", marker="o", ms=3, label=lab)
        plt.xscale("log", base=2)
        plt.title(f"{coll} busbw vs size (dashed = one HCA, solid = all)")
        plt.xlabel("message size (bytes)"); plt.ylabel("busbw (GB/s)")
        plt.legend(fontsize=8); plt.grid(alpha=0.3)
        fn = f"nccl_curve_{coll}.png"; plt.tight_layout()
        plt.savefig(os.path.join(out_dir, fn), dpi=110); plt.close()
        imgs.append((f"{coll}: one-HCA vs all-HCA", fn))
    return imgs


def _load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _read_csv_rows(path):
    try:
        with open(path) as fh:
            return list(csv.DictReader(fh))
    except OSError:
        return []


def export_all_data(runs, out_dir):
    """Write every test's numbers into flat CSVs under <report>/data/ so nothing
    is trapped in per-pod run dirs -- one row per (env, subtree, test, size)."""
    ddir = os.path.join(out_dir, "data")
    os.makedirs(ddir, exist_ok=True)
    written = []

    with open(os.path.join(ddir, "bw_summary.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["env", "subtree", "test", "size_bytes", "duration_s",
                    "bw_peak_gbps", "bw_avg_gbps", "msg_rate_mpps"])
        for r in runs:
            for subtree in SUBTREES:
                sub = (subtree + "/") if subtree else ""
                for test in BW_TESTS:
                    for row in _read_csv_rows(os.path.join(r["path"], sub + "bw", test + ".csv")):
                        w.writerow([r["label"], subtree or "nic", test,
                                    row.get("size_bytes", ""), row.get("duration_s", ""),
                                    row.get("bw_peak_gbps", ""), row.get("bw_avg_gbps", ""),
                                    row.get("msg_rate_mpps", "")])
    written.append("bw_summary.csv")

    with open(os.path.join(ddir, "lat_summary.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["env", "subtree", "test", "count", "min", "avg",
                    "p50", "p99", "p999", "max"])
        for r in runs:
            for subtree in SUBTREES:
                sub = (subtree + "/") if subtree else ""
                for test in LAT_TESTS:
                    d = _load_json(os.path.join(r["path"], sub + "lat", test + ".json"))
                    if d:
                        w.writerow([r["label"], subtree or "nic", test] +
                                   [d.get(k, "") for k in ("count", "min", "avg",
                                                           "p50", "p99", "p999", "max")])
    written.append("lat_summary.csv")

    with open(os.path.join(ddir, "nccl_summary.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["env", "collective", "one_hca", "one_busbw_gbps",
                    "all_hca", "all_busbw_gbps"])
        for r in runs:
            for coll, d in _nccl_collectives(r).items():
                w.writerow([r["label"], coll,
                            d.get("one", {}).get("hca", ""), d.get("one", {}).get("busbw", ""),
                            d.get("all", {}).get("hca", ""), d.get("all", {}).get("busbw", "")])
    written.append("nccl_summary.csv")

    with open(os.path.join(ddir, "nccl_curve.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["env", "collective", "mode", "size_bytes", "algbw_gbps", "busbw_gbps"])
        for r in runs:
            for coll in _nccl_collectives(r):
                for mode, fn in (("one-HCA", "one_hca.txt"), ("all-HCA", "all_hca.txt")):
                    for x in parse_nccl_table(os.path.join(r["path"], "nccl", coll, fn)):
                        w.writerow([r["label"], coll, mode, x["size"], x["algbw"], x["busbw"]])
    written.append("nccl_curve.csv")

    print(f"exported {len(written)} data file(s) -> {os.path.join(out_dir, 'data')}")
    return written


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

    html = ["<html><head><meta charset='utf-8'>",
            "<meta name='viewport' content='width=device-width, initial-scale=1'>",
            "<title>roce-perf report</title>", REPORT_CSS,
            "</head><body><div class='wrap'>",
            "<header><p class='eyebrow'>RoCEv2 fabric benchmark</p>"
            "<h1>roce-perf report</h1>"
            "<p class='lede'>Leaf/spine RDMA + GPUDirect + NCCL. Latency panels plot the "
            "raw <code>-U</code> samples <b>over time</b> (peaks preserved) so tail "
            "spikes stand out where the average hides them.</p></header>"]

    # ---- setup summary table -------------------------------------------------
    html.append("<h2>Setup summary</h2><div class='tablewrap'><table><tr>"
                "<th>environment</th><th>device</th><th>node</th><th>mtu</th>"
                "<th>gpudirect</th><th>date</th><th>run dir</th></tr>")
    for r in runs:
        m = r["setup"]
        html.append("<tr>" + "".join(f"<td>{html_escape(v)}</td>" for v in (
            m.get("env_label"), m.get("device"), m.get("node"), m.get("mtu"),
            m.get("gpudirect"), m.get("date"), r["name"])) + "</tr>")
    html.append("</table></div>")

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
            # Full BW table: peak + avg + message rate per env/size (not just the
            # avg the bar chart shows), so every number is visible in the report.
            sub = (subtree + "/") if subtree else ""
            btbl = [(r["label"], row) for r in runs
                    for row in _read_csv_rows(os.path.join(r["path"], sub + "bw", test + ".csv"))]
            if btbl:
                html.append(f"<p><b>{test}</b> — Gb/s peak/avg, Mpps</p>"
                            "<div class='tablewrap'><table><tr>"
                            "<th>env</th><th>size</th><th>dur(s)</th><th>peak</th>"
                            "<th>avg</th><th>msg rate</th></tr>")
                for lab, row in btbl:
                    html.append("<tr>" + f"<td>{html_escape(lab)}</td>" + "".join(
                        f"<td>{html_escape(row.get(k, 'NA'))}</td>" for k in (
                            "size_bytes", "duration_s", "bw_peak_gbps",
                            "bw_avg_gbps", "msg_rate_mpps")) + "</tr>")
                html.append("</table></div>")

        html.append("<h3>Latency (over-time peaks, CDF, histogram, percentiles)</h3>")
        for test in LAT_TESTS:
            for img in (plot_lat_timeseries(runs, test, subtree, out_dir),
                        plot_lat_cdf(runs, test, subtree, out_dir),
                        plot_lat_hist(runs, test, subtree, out_dir)):
                if img:
                    html.append(f"<img src='{img}' alt='{test}'>")
            rows = load_lat_json(runs, test, subtree)
            if rows:
                html.append(f"<p><b>{test}</b> (usec)</p>"
                            "<div class='tablewrap'><table><tr><th>env</th>"
                            "<th>min</th><th>avg</th><th>p50</th><th>p99</th><th>p99.9</th><th>max</th></tr>")
                for lab, d in rows:
                    html.append("<tr>" + f"<td>{html_escape(lab)}</td>" + "".join(
                        f"<td>{html_escape(d.get(k, 'NA'))}</td>"
                        for k in ("min", "avg", "p50", "p99", "p999", "max")) + "</tr>")
                html.append("</table></div>")

    # ---- NCCL ----------------------------------------------------------------
    nccl_bar = plot_nccl(runs, out_dir)
    nccl_curves = plot_nccl_curves(runs, out_dir)
    if nccl_bar or nccl_curves:
        html.append("<h2>NCCL collectives (one-HCA vs all-HCA)</h2>")
        html.append("<p>Each collective maps to a real traffic pattern — all_reduce "
                    "(tensor-parallel sync), alltoall (MoE dispatch/combine), "
                    "reduce_scatter (TP + sequence parallel), sendrecv (KV transfer). "
                    "Averaged busbw per collective, then per-size curves. See "
                    "<a href='../../NCCL-DEEP-DIVE.md'>NCCL-DEEP-DIVE.md</a>.</p>")
        if nccl_bar:
            html.append(f"<img src='{nccl_bar}' alt='nccl one vs all per collective'>")
        for caption, fn in nccl_curves:
            html.append(f"<h3>{html_escape(caption)}</h3><img src='{fn}' alt='{html_escape(caption)}'>")

    # ---- data exports (every raw number, flat CSVs) --------------------------
    exported = export_all_data(runs, out_dir)
    if exported:
        html.append("<h2>Data exports</h2><p>All results as flat CSVs:</p><ul>")
        for f in exported:
            html.append(f"<li><a href='data/{f}'>{html_escape(f)}</a></li>")
        html.append("</ul>")

    html.append("</div></body></html>")
    report = os.path.join(out_dir, "report.html")
    with open(report, "w") as fh:
        fh.write("\n".join(html))
    print(f"wrote {report}")


if __name__ == "__main__":
    main()
