#!/usr/bin/env python3
"""
node-perf report generator (generic / metric-driven).

Scans the results dir for run directories produced by node_bench.sh
(<label>-<timestamp>/ with setup.json), reads each run's per-group metrics.json
files, and emits a self-contained report.html comparing every label
(baseline vs tuned vs ...) with a per-metric DELTA vs the baseline.

  report.py <results_dir> [output_subdir]

The report is fully driven by the metrics.json contract -- a new benchmark that
drops a <group>/metrics.json shows up automatically, no code change here.

  metrics.json:
    {"group":"cpu","benchmark":"sysbench-cpu",
     "metrics":[{"name":..,"dim":..,"unit":..,"value":..,"higher_is_better":..}]}

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

# Preferred section order; any other group is appended alphabetically.
GROUP_ORDER = ["cpu", "mem", "disk"]
GROUP_TITLE = {"cpu": "CPU (sysbench)", "mem": "Memory (sysbench)", "disk": "Disk (fio)"}

# Self-contained, theme-aware stylesheet (no external fonts/CSS -- renders offline).
# Instrument-panel palette: cool slate neutrals + one teal accent, monospace numbers.
# .up = improvement, .down = regression (direction respects higher_is_better).
REPORT_CSS = """<style>
:root{
  --bg:#f5f7f9; --surface:#ffffff; --ink:#16202e; --muted:#5a6675;
  --hair:#e3e8ef; --accent:#0e7490; --accent-ink:#0b5566; --warn:#b4530f;
  --good:#0f7b52; --bad:#b4260f;
  --zebra:#f8fafb; --shadow:0 1px 2px rgba(16,32,48,.06),0 1px 12px rgba(16,32,48,.04);
  --sans:ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0d1117; --surface:#161b22; --ink:#e6edf3; --muted:#93a1b1;
  --hair:#232c38; --accent:#38bdf8; --accent-ink:#7dd3fc; --warn:#f0883e;
  --good:#3fb950; --bad:#f85149;
  --zebra:#1a212b; --shadow:0 1px 2px rgba(0,0,0,.4);
}}
:root[data-theme="dark"]{
  --bg:#0d1117; --surface:#161b22; --ink:#e6edf3; --muted:#93a1b1;
  --hair:#232c38; --accent:#38bdf8; --accent-ink:#7dd3fc; --warn:#f0883e;
  --good:#3fb950; --bad:#f85149;
  --zebra:#1a212b; --shadow:0 1px 2px rgba(0,0,0,.4);
}
:root[data-theme="light"]{
  --bg:#f5f7f9; --surface:#ffffff; --ink:#16202e; --muted:#5a6675;
  --hair:#e3e8ef; --accent:#0e7490; --accent-ink:#0b5566; --warn:#b4530f;
  --good:#0f7b52; --bad:#b4260f;
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
td.up{color:var(--good);font-weight:600}
td.down{color:var(--bad);font-weight:600}
.pill{font-family:var(--mono);font-size:.7rem;color:var(--muted)}
ul{padding-left:1.1rem;color:var(--muted)}
li{margin:.15rem 0}
li a{font-family:var(--mono);font-size:.9rem}
</style>"""


def _load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def discover_runs(results_dir, out_dir_name):
    """Latest run dir per label (dirname sorts ascending by timestamp)."""
    by_label = {}
    for name in sorted(os.listdir(results_dir)):
        path = os.path.join(results_dir, name)
        setup = os.path.join(path, "setup.json")
        if name == out_dir_name or not os.path.isdir(path) or not os.path.exists(setup):
            continue
        meta = _load_json(setup)
        if meta is None:
            continue
        label = meta.get("env_label", name)
        by_label[label] = {"name": name, "label": label, "path": path, "setup": meta}
    return [by_label[k] for k in sorted(by_label)]


def load_metrics(run):
    """All metric records for a run -> [{group,benchmark,name,dim,unit,value,hib}]."""
    recs = []
    for mp in sorted(glob.glob(os.path.join(run["path"], "*", "metrics.json"))):
        d = _load_json(mp)
        if not d:
            continue
        group = d.get("group", "?")
        bench = d.get("benchmark", "?")
        for m in d.get("metrics", []):
            recs.append({
                "group": group, "benchmark": bench,
                "name": m.get("name", ""), "dim": m.get("dim", "") or "",
                "unit": m.get("unit", ""),
                "value": m.get("value"),
                "hib": bool(m.get("higher_is_better", True)),
            })
    return recs


def html_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _fmt(v):
    if v is None:
        return "NA"
    try:
        f = float(v)
    except (TypeError, ValueError):
        return html_escape(v)
    if f == 0:
        return "0"
    a = abs(f)
    if a >= 1000:
        return f"{f:,.0f}"
    if a >= 1:
        return f"{f:.2f}"
    return f"{f:.4f}"


def delta_pct(base_v, v):
    try:
        base_v = float(base_v); v = float(v)
    except (TypeError, ValueError):
        return None
    if base_v == 0:
        return None
    return (v - base_v) / base_v * 100.0


def improved(hib, d):
    """Is a delta an improvement given higher-is-better?"""
    if d is None:
        return None
    return (d > 0) if hib else (d < 0)


def plot_metric(group, name, dims, unit, hib, series, labels, out_dir):
    """Grouped bar: x = dims (or the metric name when single/no dim), group = label."""
    xticklabels = [d if d else name for d in dims]
    x = np.arange(len(dims))
    width = 0.8 / max(len(labels), 1)
    plt.figure(figsize=(8, 4.5))
    any_bar = False
    for i, lab in enumerate(labels):
        vals = []
        for d in dims:
            v = series.get(lab, {}).get(d)
            vals.append(float(v) if isinstance(v, (int, float)) else 0.0)
            any_bar = any_bar or bool(vals[-1])
        plt.bar(x + i * width, vals, width, label=lab)
    if not any_bar:
        plt.close(); return None
    plt.xticks(x + width * (len(labels) - 1) / 2, xticklabels)
    plt.title(f"{group} · {name}")
    plt.ylabel(f"{unit}  ({'higher' if hib else 'lower'} is better)" if unit else "")
    plt.xlabel("")
    plt.legend()
    plt.grid(axis="y", alpha=0.3)
    fname = f"{group}_{name}.png"
    plt.tight_layout()
    plt.savefig(os.path.join(out_dir, fname), dpi=110)
    plt.close()
    return fname


def export_all_data(index, labels, base_label, out_dir):
    """Flat metrics.csv: one row per (label, group, metric, dim)."""
    ddir = os.path.join(out_dir, "data")
    os.makedirs(ddir, exist_ok=True)
    path = os.path.join(ddir, "metrics.csv")
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["label", "group", "benchmark", "metric", "dim", "unit",
                    "value", "delta_pct_vs_baseline", "higher_is_better"])
        for (group, name, dim), per_label in index.items():
            base = per_label.get(base_label, {})
            base_v = base.get("value")
            for lab in labels:
                rec = per_label.get(lab)
                if not rec:
                    continue
                d = delta_pct(base_v, rec["value"]) if lab != base_label else None
                w.writerow([lab, group, name, dim, rec["unit"],
                            rec["value"], "" if d is None else f"{d:.2f}", rec["hib"]])
    print(f"exported metrics.csv -> {path}")
    return ["metrics.csv"]


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: report.py <results_dir> [output_subdir]")
    results_dir = sys.argv[1]
    out_name = sys.argv[2] if len(sys.argv) > 2 else "report"
    out_dir = os.path.join(results_dir, out_name)
    os.makedirs(out_dir, exist_ok=True)

    runs = discover_runs(results_dir, out_name)
    if not runs:
        sys.exit(f"no run directories with setup.json found under {results_dir}")
    labels = [r["label"] for r in runs]
    print(f"found {len(runs)} run(s): {', '.join(labels)}")

    base_label = os.environ.get("REPORT_BASELINE", "baseline")
    if base_label not in labels:
        base_label = labels[0]
    print(f"baseline label: {base_label}")

    # Build the metric index: (group, name, dim) -> {label: rec}. Preserve the
    # order metrics were first seen (per group) for stable section layout.
    index = {}
    order = []  # (group, name) in first-seen order
    dims_by_metric = {}  # (group, name) -> [dims in first-seen order]
    for r in runs:
        for rec in load_metrics(r):
            key = (rec["group"], rec["name"], rec["dim"])
            index.setdefault(key, {})[r["label"]] = rec
            gm = (rec["group"], rec["name"])
            if gm not in dims_by_metric:
                dims_by_metric[gm] = []
                order.append(gm)
            if rec["dim"] not in dims_by_metric[gm]:
                dims_by_metric[gm].append(rec["dim"])

    if not index:
        sys.exit("runs found but no metrics.json inside them -- did the benchmarks run?")

    # Group ordering: known groups first (GROUP_ORDER), then any others.
    groups = []
    for g in GROUP_ORDER:
        if any(gm[0] == g for gm in order):
            groups.append(g)
    for gm in order:
        if gm[0] not in groups:
            groups.append(gm[0])

    html = ["<html><head><meta charset='utf-8'>",
            "<meta name='viewport' content='width=device-width, initial-scale=1'>",
            "<title>node-perf report</title>", REPORT_CSS,
            "</head><body><div class='wrap'>",
            "<header><p class='eyebrow'>Node performance-tuning benchmark</p>"
            "<h1>node-perf report</h1>"
            "<p class='lede'>CPU, memory, and disk benchmarks per node. Each metric is "
            "compared across run labels, with the <b>&Delta;% vs "
            f"<code>{html_escape(base_label)}</code></b> coloured by whether it is an "
            "improvement or a regression &mdash; so the effect of a tuning change is "
            "readable at a glance.</p></header>"]

    # ---- setup / what-changed summary ---------------------------------------
    html.append("<h2>Runs &amp; node configuration</h2>"
                "<p>What each labelled run was measured under (this is where you see "
                "<i>what changed</i> between baseline and tuned).</p>"
                "<div class='tablewrap'><table><tr>"
                "<th>label</th><th>node</th><th>kernel</th><th>cpu</th><th>cores</th>"
                "<th>mem</th><th>governor</th><th>hugepages</th><th>thp</th>"
                "<th>tuned</th><th>note</th><th>date</th></tr>")
    for r in runs:
        m = r["setup"]
        cells = [m.get("label"), m.get("node"), m.get("kernel"), m.get("cpu_model"),
                 m.get("cpu_cores"), m.get("mem_total"), m.get("governor"),
                 m.get("hugepages"), m.get("thp"), m.get("tuned"), m.get("note"),
                 m.get("date")]
        html.append("<tr>" + "".join(f"<td>{html_escape(v)}</td>" for v in cells) + "</tr>")
    html.append("</table></div>")

    # ---- per-group metric sections ------------------------------------------
    non_base = [l for l in labels if l != base_label]
    for group in groups:
        html.append(f"<h2>{html_escape(GROUP_TITLE.get(group, group))}</h2>")
        for (g, name) in order:
            if g != group:
                continue
            dims = dims_by_metric[(g, name)]
            # unit + hib from any present record
            sample = None
            for d in dims:
                sample = index.get((g, name, d), {})
                if sample:
                    sample = next(iter(sample.values()))
                    break
            unit = sample["unit"] if sample else ""
            hib = sample["hib"] if sample else True

            # series[label][dim] = value  (for the bar chart)
            series = {}
            for d in dims:
                for lab, rec in index.get((g, name, d), {}).items():
                    series.setdefault(lab, {})[d] = rec["value"]

            img = plot_metric(group, name, dims, unit, hib, series, labels, out_dir)
            arrow = "higher is better" if hib else "lower is better"
            html.append(f"<h3>{html_escape(name)} "
                        f"<span class='pill'>{html_escape(unit)} &middot; {arrow}</span></h3>")
            if img:
                html.append(f"<img src='{img}' alt='{html_escape(name)}'>")

            # comparison table: dim | each label value | Δ% for each non-baseline label
            head = ["dim"] + [html_escape(l) for l in labels] + \
                   [f"&Delta;% {html_escape(l)}" for l in non_base]
            html.append("<div class='tablewrap'><table><tr>" +
                        "".join(f"<th>{h}</th>" for h in head) + "</tr>")
            for d in dims:
                per_label = index.get((g, name, d), {})
                base_v = per_label.get(base_label, {}).get("value")
                row = [f"<td>{html_escape(d if d else name)}</td>"]
                for lab in labels:
                    rec = per_label.get(lab)
                    row.append(f"<td>{_fmt(rec['value']) if rec else 'NA'}</td>")
                for lab in non_base:
                    rec = per_label.get(lab)
                    dp = delta_pct(base_v, rec["value"]) if rec else None
                    if dp is None:
                        row.append("<td>NA</td>")
                    else:
                        cls = "up" if improved(hib, dp) else "down"
                        sign = "+" if dp >= 0 else ""
                        row.append(f"<td class='{cls}'>{sign}{dp:.1f}%</td>")
                html.append("<tr>" + "".join(row) + "</tr>")
            html.append("</table></div>")

    # ---- data export --------------------------------------------------------
    exported = export_all_data(index, labels, base_label, out_dir)
    if exported:
        html.append("<h2>Data export</h2><p>All metrics as one flat CSV:</p><ul>")
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
