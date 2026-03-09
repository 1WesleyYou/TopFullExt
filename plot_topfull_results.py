#!/usr/bin/env python3
"""
Plot TopFull experiment results from CSV logs.

Default behavior:
- Auto-detect logs directory from global_config.json if possible.
- Generate two figures:
  1) total_metrics.png (RPS / Goodput / Fail / Latency95)
  2) api_goodput.png   (per-API Goodput curves)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
from pathlib import Path
from typing import Dict, List

import matplotlib.pyplot as plt

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

# Upstream (shallow) -> downstream (deep)
API_DEPTH_ORDER = ["getproduct", "getcart", "postcart", "emptycart", "postcheckout"]


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


def plot_total(total_rows: List[Dict[str, str]], output_path: Path) -> None:
    t = list(range(len(total_rows)))
    rps = to_float_list(total_rows, "RPS")
    fail = to_float_list(total_rows, "Fail")
    goodput = to_float_list(total_rows, "Goodput")
    lat95 = to_float_list(total_rows, "Latency95")

    fig, axes = plt.subplots(3, 1, figsize=(11, 8), sharex=True)

    axes[0].plot(t, rps, label="RPS", color=CB_COLORS["sky"], linestyle="--", linewidth=1.8, alpha=0.95)
    axes[0].plot(t, goodput, label="Goodput", color=CB_COLORS["blue"], linestyle="-", linewidth=2.2)
    axes[0].set_ylabel("req/s")
    axes[0].legend()
    axes[0].grid(alpha=0.25)

    axes[1].plot(t, fail, color=CB_COLORS["red"], linestyle="-", linewidth=2.0, label="Fail")
    axes[1].set_ylabel("fail/s")
    axes[1].legend()
    axes[1].grid(alpha=0.25)

    axes[2].plot(t, lat95, color=CB_COLORS["orange"], linestyle="-.", linewidth=2.0, label="Latency95")
    axes[2].set_ylabel("ms")
    axes[2].set_xlabel("time index (1 row = 1 sample)")
    axes[2].legend()
    axes[2].grid(alpha=0.25)

    fig.suptitle("TopFull Total Metrics")
    fig.tight_layout()
    fig.savefig(output_path, dpi=160)
    plt.close(fig)


def plot_api_goodput(
    logs_dir: Path,
    apis: List[str],
    output_path: Path,
    max_points: int | None = None,
) -> None:
    fig, ax = plt.subplots(1, 1, figsize=(11, 4.5))
    any_curve = False
    line_by_api = {}

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
        x = list(range(len(y)))
        color, linestyle = API_STYLE.get(api, (CB_COLORS["black"], "-"))
        # marker sparsely to improve distinguishability without clutter
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

    ax.set_title("Per-API Goodput")
    ax.set_xlabel("time index (1 row = 1 sample)")
    ax.set_ylabel("goodput")
    ax.grid(alpha=0.25)
    legend_apis = [api for api in apis if api in line_by_api]
    legend_handles = [line_by_api[api] for api in legend_apis]
    ax.legend(legend_handles, legend_apis, framealpha=0.95)
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
        default="getproduct,getcart,postcart,emptycart,postcheckout",
        help="Comma-separated API names for per-API goodput chart",
    )
    parser.add_argument(
        "--trim-zero-tail",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Trim trailing all-zero rows by total RPS/Fail/Goodput (default: true)",
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

    total_out = out_dir / f"{args.prefix}_total_metrics.png"
    api_out = out_dir / f"{args.prefix}_api_goodput.png"

    plot_total(total_rows, total_out)
    plot_api_goodput(logs_dir, apis, api_out, max_points=used_total_rows)

    print(f"logs_dir={logs_dir}")
    print(f"rows_total={original_total_rows}")
    print(f"rows_used={used_total_rows}")
    print(f"saved={total_out}")
    print(f"saved={api_out}")


if __name__ == "__main__":
    main()

