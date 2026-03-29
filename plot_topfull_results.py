#!/usr/bin/env python3
"""
Plot TopFull experiment results from CSV logs.

Default behavior:
- Auto-detect logs directory from global_config.json if possible.
- Generate two figures:
  1) total_metrics.png (RPS / Goodput / Fail / Latency95 / Latency99)
  2) api_goodput.png   (per-API Goodput curves)
- X axis is **seconds since the first sample** (integer s). With a ``timestamp`` column,
  ``t[i] = round((row[i].time - row[0].time).total_seconds())``. Without timestamps,
  ``t[i] = round(i * METRIC_SAMPLE_SEC)`` from phase_markers (default 1 s).
  Vertical lines: ``SURGE_*_ISO`` relative to the first row's time, else ``SURGE_*_INDEX`` mapped through the same axis.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple

import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

# Color-blind-friendly palette (Okabe-Ito)
CB_COLORS = {
    "blue": "#0072B2",
    "orange": "#E69F00",
    "green": "#009E73",
    "red": "#D55E00",
    "purple": "#CC79A7",
    "black": "#000000",
    "sky": "#56B4E9",
}

API_STYLE = {
    "getcart": (CB_COLORS["blue"], "-"),
    "getproduct": (CB_COLORS["orange"], "--"),
    "postcheckout": (CB_COLORS["green"], "-."),
    "postcart": (CB_COLORS["red"], ":"),
    "emptycart": (CB_COLORS["purple"], (0, (3, 1, 1, 1))),
}

# Hardcoded API order: short path -> long path
API_DEPTH_ORDER = ["emptycart", "postcart", "getcart", "getproduct", "postcheckout"]


def detect_logs_dir(explicit_logs_dir: str | None) -> Path:
    if explicit_logs_dir:
        return Path(explicit_logs_dir).expanduser()

    repo_root = Path(__file__).resolve().parent
    config_path = repo_root / "TopFull_master" / "online_boutique_scripts" / "src" / "global_config.json"
    if config_path.exists():
        try:
            cfg = json.loads(config_path.read_text())
            record_path = cfg.get("record_path")
            if isinstance(record_path, str) and record_path.strip():
                return Path(os.path.expandvars(os.path.expanduser(record_path)))
        except Exception:
            pass

    return Path("~/TopFullExt/TopFull_master/online_boutique_scripts/src/logs").expanduser()


def read_simple_env_file(path: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        env[k.strip()] = v.strip()
    return env


def sync_logs_from_master(
    local_logs_dir: Path,
    master_node: str,
    ssh_user: str,
    remote_logs_dir: str,
) -> None:
    local_logs_dir.mkdir(parents=True, exist_ok=True)
    target = f"{ssh_user}@{master_node}" if ssh_user else master_node
    remote_spec = f"{target}:{remote_logs_dir.rstrip('/')}" + "/*.csv"
    cmd = ["scp", remote_spec, str(local_logs_dir)]
    subprocess.run(cmd, check=True)


def read_csv_rows(path: Path) -> List[Dict[str, str]]:
    with path.open("r", newline="") as f:
        return list(csv.DictReader(f))


def to_float_list(rows: List[Dict[str, str]], key: str) -> List[float]:
    values: List[float] = []
    for row in rows:
        raw = row.get(key, "0")
        try:
            values.append(float(raw))
        except Exception:
            values.append(0.0)
    return values


def trim_trailing_zero_rows(
    rows: List[Dict[str, str]],
    keys: List[str],
    eps: float = 1e-9,
) -> List[Dict[str, str]]:
    last_nonzero = -1
    for idx, row in enumerate(rows):
        for key in keys:
            raw = row.get(key, "0")
            try:
                value = float(raw)
            except Exception:
                value = 0.0
            if abs(value) > eps:
                last_nonzero = idx
                break

    if last_nonzero < 0:
        return rows[:1] if rows else rows
    return rows[: last_nonzero + 1]


def sort_apis_by_depth(apis: List[str]) -> List[str]:
    order_idx = {api: i for i, api in enumerate(API_DEPTH_ORDER)}
    return sorted(apis, key=lambda a: (order_idx.get(a, len(API_DEPTH_ORDER)), a))


def read_phase_markers(path: Path) -> Dict[str, str]:
    if not path.exists():
        return {}
    out: Dict[str, str] = {}
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def _parse_iso_ts(raw: str) -> datetime | None:
    s = raw.strip().strip('"').strip("'")
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def _metric_sample_sec(markers: Dict[str, str], default: float = 1.0) -> float:
    try:
        v = float(markers.get("METRIC_SAMPLE_SEC", ""))
        return v if v > 0 else default
    except ValueError:
        return default


def build_relative_sec_axis(
    rows: List[Dict[str, str]],
    markers: Dict[str, str],
) -> Tuple[List[int], datetime | None]:
    """
    Integer seconds since the first row: 0, d1, d2, … (1 s display precision).

    With timestamps: offset from first row's parsed time.
    Without: i * METRIC_SAMPLE_SEC rounded to int.
    """
    if not rows:
        return [], None
    step = _metric_sample_sec(markers, 1.0)
    if "timestamp" not in rows[0]:
        return [int(round(i * step)) for i in range(len(rows))], None

    t0 = _parse_iso_ts(rows[0].get("timestamp", ""))
    if t0 is None:
        return [int(round(i * step)) for i in range(len(rows))], None

    xs: List[int] = []
    for row in rows:
        dt = _parse_iso_ts(row.get("timestamp", ""))
        if dt is None:
            return [int(round(i * step)) for i in range(len(rows))], None
        xs.append(int(round((dt - t0).total_seconds())))
    return xs, t0


def surge_vertical_lines_sec(
    markers: Dict[str, str],
    t0: datetime | None,
    x_sec: List[int],
) -> List[Tuple[float, str]]:
    """Phase markers in seconds on the same axis as ``x_sec``."""
    lines: List[Tuple[float, str]] = []
    if t0 is not None:
        for key, label in (("SURGE_START_ISO", "surge start"), ("SURGE_END_ISO", "surge end")):
            raw = markers.get(key, "").strip()
            if not raw:
                continue
            dt = _parse_iso_ts(raw)
            if dt is None:
                continue
            sec = int(round((dt - t0).total_seconds()))
            lines.append((float(sec), f"{label} ({sec}s)"))
        if lines:
            return lines

    step = _metric_sample_sec(markers, 1.0)
    for key, label in (("SURGE_START_INDEX", "surge start"), ("SURGE_END_INDEX", "surge end")):
        raw = markers.get(key)
        if not raw:
            continue
        try:
            idx = int(float(raw))
        except ValueError:
            continue
        if x_sec and 0 <= idx < len(x_sec):
            sec = x_sec[idx]
        else:
            sec = int(round(idx * step))
        lines.append((float(sec), f"{label} ({sec}s)"))
    return lines


def add_vertical_markers(
    axes: List[object],
    lines: List[Tuple[float, str]],
    x_min: float,
    x_max: float,
    label_axis: int | None = 0,
) -> None:
    """Draw dashed vertical lines. If label_axis is set, only axes[label_axis] gets legend labels."""
    if not lines or not axes:
        return
    lo, hi = float(min(x_min, x_max)), float(max(x_min, x_max))
    for ai, ax in enumerate(axes):
        use_label = label_axis is not None and ai == label_axis
        for x_val, label in lines:
            xv = max(lo, min(float(x_val), hi))
            lbl = label if use_label else "_nolegend_"
            ax.axvline(
                xv,
                color="#555555",
                linestyle="--",
                linewidth=1.3,
                alpha=0.9,
                label=lbl,
                zorder=5,
            )


def _style_sec_xaxis(ax: object) -> None:
    ax.xaxis.set_major_locator(MaxNLocator(nbins=9, integer=True, min_n_ticks=4))


def plot_total(
    total_rows: List[Dict[str, str]],
    output_path: Path,
    phase_markers: Dict[str, str] | None = None,
    x_sec: List[int] | None = None,
    t0: datetime | None = None,
) -> None:
    pm = phase_markers or {}
    if x_sec is None:
        x_sec, t0 = build_relative_sec_axis(total_rows, pm)
    elif t0 is None:
        _, t0 = build_relative_sec_axis(total_rows, pm)
    t = [float(x) for x in x_sec]
    x_lo, x_hi = float(t[0]), float(t[-1])
    rps = to_float_list(total_rows, "RPS")
    fail = to_float_list(total_rows, "Fail")
    goodput = to_float_list(total_rows, "Goodput")
    lat95 = to_float_list(total_rows, "Latency95")
    lat99 = to_float_list(total_rows, "Latency99")

    fig, axes = plt.subplots(3, 1, figsize=(11, 8), sharex=True)

    axes[0].plot(t, rps, label="RPS", color=CB_COLORS["sky"], linestyle="--", linewidth=1.8, alpha=0.95)
    axes[0].plot(t, goodput, label="Goodput", color=CB_COLORS["blue"], linestyle="-", linewidth=2.2)
    axes[0].set_ylabel("req/s")
    axes[0].grid(alpha=0.25)

    axes[1].plot(t, fail, color=CB_COLORS["red"], linestyle="-", linewidth=2.0, label="Fail")
    axes[1].set_ylabel("fail/s")
    axes[1].grid(alpha=0.25)

    axes[2].plot(t, lat95, color=CB_COLORS["orange"], linestyle="-.", linewidth=2.0, label="Latency95")
    axes[2].plot(t, lat99, color=CB_COLORS["purple"], linestyle=":", linewidth=2.0, label="Latency99")
    axes[2].set_ylabel("ms")
    axes[2].set_xlabel("time since first sample (s)")
    axes[2].grid(alpha=0.25)

    mv = surge_vertical_lines_sec(pm, t0, x_sec)
    if mv:
        add_vertical_markers(list(axes), mv, x_lo, x_hi, label_axis=0)

    for ax in axes:
        _style_sec_xaxis(ax)

    axes[0].legend()
    axes[1].legend()
    axes[2].legend()

    fig.suptitle("TopFull Total Metrics")
    fig.tight_layout()
    fig.savefig(output_path, dpi=160)
    plt.close(fig)


def plot_api_goodput(
    logs_dir: Path,
    apis: List[str],
    output_path: Path,
    max_points: int | None = None,
    phase_markers: Dict[str, str] | None = None,
    x_sec_from_total: List[int] | None = None,
    t0_from_total: datetime | None = None,
) -> None:
    fig, ax = plt.subplots(1, 1, figsize=(11, 4.8))
    any_curve = False
    line_by_api: Dict[str, object] = {}

    max_xlen = 0
    x_lo: float | None = None
    x_hi: float | None = None
    pm = phase_markers or {}

    for api in apis:
        csv_path = logs_dir / f"{api}.csv"
        if not csv_path.exists():
            continue
        rows = read_csv_rows(csv_path)
        if max_points is not None:
            rows = rows[:max_points]
        if not rows:
            continue
        y = to_float_list(rows, "Goodput")
        max_xlen = max(max_xlen, len(y))
        if x_sec_from_total is not None and len(x_sec_from_total) >= len(y):
            x = [float(v) for v in x_sec_from_total[: len(y)]]
        else:
            xs, _ = build_relative_sec_axis(rows, pm)
            x = [float(v) for v in xs]
        xf0, xf1 = float(x[0]), float(x[-1])
        if x_lo is None:
            x_lo, x_hi = xf0, xf1
        else:
            x_lo = min(x_lo, xf0)
            x_hi = max(x_hi, xf1)
        color, linestyle = API_STYLE.get(api, (CB_COLORS["black"], "-"))
        markevery = max(1, len(x) // 30)
        line, = ax.plot(
            x,
            y,
            label=api,
            color=color,
            linestyle=linestyle,
            linewidth=2.2,
            marker="o",
            markersize=3.0,
            markevery=markevery,
            alpha=0.95,
        )
        line_by_api[api] = line
        any_curve = True

    if not any_curve:
        raise RuntimeError(f"No API CSV curves found under: {logs_dir}")

    ax.set_title("Per-API Goodput (hardcoded short -> long order)")
    ax.set_xlabel("time since first sample (s)")
    ax.set_ylabel("goodput")
    ax.grid(alpha=0.25)
    _style_sec_xaxis(ax)

    ref_x = x_sec_from_total if x_sec_from_total is not None else []
    mv = surge_vertical_lines_sec(pm, t0_from_total, ref_x)
    if mv and max_xlen > 0 and x_lo is not None and x_hi is not None:
        add_vertical_markers([ax], mv, x_lo, x_hi, label_axis=0)
    h_all, lab_all = ax.get_legend_handles_labels()
    ax.legend(h_all, lab_all, framealpha=0.95)
    fig.tight_layout()
    fig.savefig(output_path, dpi=160)
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser(description="Plot TopFull metrics from CSV logs.")
    parser.add_argument("--logs-dir", default=None, help="Path to logs directory containing total.csv and <api>.csv")
    parser.add_argument("--out-dir", default=".", help="Directory to save output images")
    parser.add_argument("--prefix", default="topfull", help="Output filename prefix")
    parser.add_argument(
        "--sync-first",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Sync CSV logs from master via scp before plotting (default: true)",
    )
    parser.add_argument("--master-node", default=None, help="Master node host (default from .env/MASTER_NODE or node0)")
    parser.add_argument("--ssh-user", default=None, help="SSH user (default from .env/SSH_USER or current)")
    parser.add_argument(
        "--remote-logs-dir",
        default=None,
        help="Remote logs dir on master (default: ~/TopFullExt/TopFull_master/online_boutique_scripts/src/logs)",
    )
    parser.add_argument(
        "--apis",
        default="emptycart,postcart,getcart,getproduct,postcheckout",
        help="Comma-separated API names for per-API goodput chart",
    )
    parser.add_argument(
        "--trim-zero-tail",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Trim trailing all-zero rows by total RPS/Fail/Goodput (default: true)",
    )
    parser.add_argument(
        "--phase-markers",
        default=None,
        help="Path to phase_markers.env (default: phase_markers.env next to this script)",
    )
    args = parser.parse_args()

    logs_dir = detect_logs_dir(args.logs_dir)
    env_file = Path(__file__).resolve().parent / ".env"
    file_env = read_simple_env_file(env_file)

    if args.sync_first:
        master_node = (
            args.master_node
            or os.environ.get("MASTER_NODE")
            or file_env.get("MASTER_NODE")
            or "node0"
        )
        ssh_user = (
            args.ssh_user
            or os.environ.get("SSH_USER")
            or file_env.get("SSH_USER")
            or ""
        )
        project_name = (
            os.environ.get("PROJECT_NAME")
            or file_env.get("PROJECT_NAME")
            or "TopFullExt"
        )
        remote_logs_dir = (
            args.remote_logs_dir
            or f"~/{project_name}/TopFull_master/online_boutique_scripts/src/logs"
        )
        sync_logs_from_master(logs_dir, master_node, ssh_user, remote_logs_dir)

    out_dir = Path(args.out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)

    total_csv = logs_dir / "total.csv"
    if not total_csv.exists():
        raise FileNotFoundError(f"Missing total.csv: {total_csv}")

    total_rows = read_csv_rows(total_csv)
    if not total_rows:
        raise RuntimeError(f"total.csv has no rows: {total_csv}")
    original_total_rows = len(total_rows)
    if args.trim_zero_tail:
        total_rows = trim_trailing_zero_rows(total_rows, ["RPS", "Fail", "Goodput"])
    used_total_rows = len(total_rows)

    apis = [a.strip() for a in args.apis.split(",") if a.strip()]
    apis = sort_apis_by_depth(apis)

    phase_path = (
        Path(args.phase_markers).expanduser()
        if args.phase_markers
        else Path(__file__).resolve().parent / "phase_markers.env"
    )
    phase_markers = read_phase_markers(phase_path)

    total_out = out_dir / f"{args.prefix}_total_metrics.png"
    api_out = out_dir / f"{args.prefix}_api_goodput.png"

    x_sec, t0 = build_relative_sec_axis(total_rows, phase_markers)

    plot_total(total_rows, total_out, phase_markers=phase_markers, x_sec=x_sec, t0=t0)
    plot_api_goodput(
        logs_dir,
        apis,
        api_out,
        max_points=used_total_rows,
        phase_markers=phase_markers,
        x_sec_from_total=x_sec,
        t0_from_total=t0,
    )

    print(f"logs_dir={logs_dir}")
    print(f"rows_total={original_total_rows}")
    print(f"rows_used={used_total_rows}")
    print(f"phase_markers={phase_path} present={phase_path.exists()}")
    print(f"api_order_short_to_long={','.join(apis)}")
    print(f"saved={total_out}")
    print(f"saved={api_out}")


if __name__ == "__main__":
    main()

