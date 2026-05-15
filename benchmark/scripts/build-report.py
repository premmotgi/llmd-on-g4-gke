#!/usr/bin/env python3
"""
build-report.py — walks a results directory and produces a side-by-side
HTML report comparing plain-vLLM vs llm-d across machine types and scenarios.

Input layout (produced by run-sweep.sh):

    results/<timestamp>/
        plain-vllm__1gpu__low-concurrency/
            benchmark_report.json
            ...
        plain-vllm__1gpu__mid-concurrency/
        ...
        llm-d__1gpu__low-concurrency/
        ...

Output:
    results/<timestamp>/comparison-report.html
    results/<timestamp>/comparison-report.md
    results/<timestamp>/comparison-summary.csv
"""

import json
import sys
from pathlib import Path
import statistics
from datetime import datetime, timezone
import html

# ----------------------------------------------------------------------------

METRICS_OF_INTEREST = {
    "ttft_p50_ms":            ("TTFT p50",  "ms",   "lower"),
    "ttft_p99_ms":            ("TTFT p99",  "ms",   "lower"),
    "tpot_p50_ms":            ("TPOT p50",  "ms",   "lower"),
    "tpot_p99_ms":            ("TPOT p99",  "ms",   "lower"),
    "output_throughput_tps":  ("Output throughput", "tok/s", "higher"),
    "request_throughput_rps": ("Request throughput", "req/s", "higher"),
    "kv_cache_hit_rate":      ("KV cache hit rate", "%",  "higher"),
}


def load_cell(path: Path) -> dict | None:
    """Load benchmark_report.json from a cell directory."""
    report = path / "benchmark_report.json"
    if not report.exists():
        # llm-d-benchmark might write it inside a subdir; search.
        candidates = list(path.rglob("benchmark_report.json"))
        if not candidates:
            return None
        report = candidates[0]
    with report.open() as fh:
        return json.load(fh)


def extract_metrics(report: dict) -> dict:
    """Pull the metrics we care about from the benchmark_report schema."""
    out = {}
    summary = report.get("summary", {})
    for key in METRICS_OF_INTEREST:
        if key in summary:
            out[key] = summary[key]
    return out


def render_markdown(rows: list[dict], outpath: Path) -> str:
    md_lines = ["# Plain vLLM vs llm-d — Gemma 4 E4B on GKE", ""]
    md_lines.append(f"_Generated {datetime.now(timezone.utc).isoformat()}Z_")
    md_lines.append("")

    # One table per scenario.
    scenarios = sorted({r["scenario"] for r in rows})
    sizes = sorted({r["size"] for r in rows})

    for scen in scenarios:
        md_lines.append(f"## Scenario: `{scen}`")
        md_lines.append("")
        header = ["Machine size", "Stack"] + [v[0] for v in METRICS_OF_INTEREST.values()]
        md_lines.append("| " + " | ".join(header) + " |")
        md_lines.append("|" + "|".join(["---"] * len(header)) + "|")

        for size in sizes:
            for stack in ("plain-vllm", "llm-d"):
                cell = next(
                    (r for r in rows if r["scenario"] == scen and r["size"] == size and r["stack"] == stack),
                    None,
                )
                if cell is None:
                    continue
                row = [size, stack]
                for key in METRICS_OF_INTEREST:
                    v = cell["metrics"].get(key)
                    row.append("—" if v is None else f"{v:.1f}")
                md_lines.append("| " + " | ".join(row) + " |")
        md_lines.append("")

    text = "\n".join(md_lines)
    outpath.write_text(text)
    return text


def render_html(rows: list[dict], outpath: Path):
    scenarios = sorted({r["scenario"] for r in rows})
    sizes = sorted({r["size"] for r in rows})

    style = """
    body { font-family: -apple-system, system-ui, sans-serif; max-width: 1200px; margin: 2em auto; padding: 0 1em; }
    h1 { border-bottom: 2px solid #333; }
    h2 { margin-top: 2em; color: #444; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 1.5em; }
    th, td { padding: 8px 12px; text-align: right; border-bottom: 1px solid #eee; }
    th { background: #f5f5f5; text-align: left; }
    td:first-child, td:nth-child(2) { text-align: left; }
    .plain { background: #fff8f0; }
    .llmd  { background: #f0f8ff; }
    .win-llmd  { color: #0a7; font-weight: 600; }
    .win-plain { color: #c50; font-weight: 600; }
    .caveat { color: #888; font-style: italic; font-size: 0.9em; }
    """

    parts = [
        "<!DOCTYPE html><html><head><meta charset='utf-8'>",
        f"<title>Gemma 4 E4B — vLLM vs llm-d</title>",
        f"<style>{style}</style></head><body>",
        "<h1>Plain vLLM vs llm-d — Gemma 4 E4B on GKE</h1>",
        f"<p class='caveat'>Generated {datetime.now(timezone.utc).isoformat()}Z</p>",
    ]

    for scen in scenarios:
        parts.append(f"<h2>Scenario: <code>{html.escape(scen)}</code></h2>")
        parts.append("<table>")
        header = ["Machine size", "Stack"] + [v[0] for v in METRICS_OF_INTEREST.values()]
        parts.append("<tr>" + "".join(f"<th>{html.escape(h)}</th>" for h in header) + "</tr>")

        for size in sizes:
            # Build a 2-row block for plain vs llm-d.
            pairs = {}
            for stack in ("plain-vllm", "llm-d"):
                cell = next(
                    (r for r in rows if r["scenario"] == scen and r["size"] == size and r["stack"] == stack),
                    None,
                )
                pairs[stack] = cell

            for stack, cell in pairs.items():
                cls = "plain" if stack == "plain-vllm" else "llmd"
                row_cells = [f"<td>{html.escape(size)}</td>", f"<td>{stack}</td>"]
                if cell is None:
                    row_cells.extend(["<td>—</td>"] * len(METRICS_OF_INTEREST))
                else:
                    for key, (_, _, direction) in METRICS_OF_INTEREST.items():
                        v = cell["metrics"].get(key)
                        other = pairs.get("llm-d" if stack == "plain-vllm" else "plain-vllm")
                        other_v = (other or {}).get("metrics", {}).get(key) if other else None

                        win_class = ""
                        if v is not None and other_v is not None:
                            better = (v < other_v) if direction == "lower" else (v > other_v)
                            if better:
                                win_class = "win-llmd" if stack == "llm-d" else "win-plain"

                        text = "—" if v is None else f"{v:.1f}"
                        row_cells.append(f"<td class='{win_class}'>{text}</td>")
                parts.append(f"<tr class='{cls}'>" + "".join(row_cells) + "</tr>")
        parts.append("</table>")

    parts.append(
        "<p class='caveat'>Green = winning value for this metric in this row pair. "
        "Latency-style metrics (TTFT, TPOT, e2e) — lower is better. "
        "Throughput-style metrics — higher is better. "
        "A small win on a single replica usually means noise; the real story is in "
        "mid- and max-throughput scenarios on multi-replica machines.</p>"
    )
    parts.append("</body></html>")
    outpath.write_text("".join(parts))


def render_csv(rows: list[dict], outpath: Path):
    headers = ["scenario", "size", "stack"] + list(METRICS_OF_INTEREST.keys())
    lines = [",".join(headers)]
    for r in rows:
        line = [r["scenario"], r["size"], r["stack"]]
        for key in METRICS_OF_INTEREST:
            v = r["metrics"].get(key)
            line.append("" if v is None else f"{v:.4f}")
        lines.append(",".join(line))
    outpath.write_text("\n".join(lines))


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <results-dir>", file=sys.stderr)
        sys.exit(1)
    results_dir = Path(sys.argv[1]).resolve()
    if not results_dir.is_dir():
        print(f"not a directory: {results_dir}", file=sys.stderr)
        sys.exit(1)

    rows = []
    for cell_dir in sorted(results_dir.iterdir()):
        if not cell_dir.is_dir():
            continue
        name = cell_dir.name
        # Expected: <stack>__<size>__<scenario>
        parts = name.split("__")
        if len(parts) != 3:
            continue
        stack, size, scenario = parts

        report = load_cell(cell_dir)
        if report is None:
            print(f"  · no report in {cell_dir}, skipping")
            continue

        metrics = extract_metrics(report)
        rows.append({"stack": stack, "size": size, "scenario": scenario, "metrics": metrics})

    if not rows:
        print("no cells found", file=sys.stderr)
        sys.exit(1)

    render_markdown(rows, results_dir / "comparison-report.md")
    render_html(rows, results_dir / "comparison-report.html")
    render_csv(rows, results_dir / "comparison-summary.csv")
    print(f"wrote {len(rows)} cells → {results_dir}/comparison-report.{{md,html}}, comparison-summary.csv")


if __name__ == "__main__":
    main()
