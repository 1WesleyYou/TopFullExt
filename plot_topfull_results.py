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


def plot_total(total_rows: List[Dict[str, str]], output_path: Path) -> None:
    t = list(range(len(total_rows)))
    rps = to_float_list(total_rows, "RPS")
    fail = to_float_list(total_rows, "Fail")
    goodput = to_float_list(total_rows, "Goodput")
    lat95 = to_float_list(total_rows, "Latency95")

    fig, axes = plt.subplots(3, 1, figsize=(11, 8), sharex=True)

    axes[0].plot(t, rps, label="RPS", alpha=0.75)
    axes[0].plot(t, goodput, label="Goodput", linewidth=1.6)
    axes[0].set_ylabel("req/s")
    axes[0].legend()
    axes[0].grid(alpha=0.25)

    axes[1].plot(t, fail, color="red", label="Fail")
    axes[1].set_ylabel("fail/s")
    axes[1].legend()
    axes[1].grid(alpha=0.25)

    axes[2].plot(t, lat95, color="orange", label="Latency95")
    axes[2].set_ylabel("ms")
    axes[2].set_xlabel("time index (1 row = 1 sample)")
    axes[2].legend()
    axes[2].grid(alpha=0.25)

    fig.suptitle("TopFull Total Metrics")
    fig.tight_layout()
    fig.savefig(output_path, dpi=160)
    plt.close(fig)


def plot_api_goodput(logs_dir: Path, apis: List[str], output_path: Path) -> None:
    fig, ax = plt.subplots(1, 1, figsize=(11, 4.5))
    any_curve = False

    for api in apis:
        csv_path = logs_dir / f"{api}.csv"
        if not csv_path.exists():
            continue
        rows = read_csv_rows(csv_path)
        if not rows:
            continue
        y = to_float_list(rows, "Goodput")
        x = list(range(len(y)))
        ax.plot(x, y, label=api)
        any_curve = True

    if not any_curve:
        raise RuntimeError(f"No API CSV curves found under: {logs_dir}")

    ax.set_title("Per-API Goodput")
    ax.set_xlabel("time index (1 row = 1 sample)")
    ax.set_ylabel("goodput")
    ax.grid(alpha=0.25)
    ax.legend()
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
        default="getcart,getproduct,postcheckout,postcart,emptycart",
        help="Comma-separated API names for per-API goodput chart",
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

    apis = [a.strip() for a in args.apis.split(",") if a.strip()]

    total_out = out_dir / f"{args.prefix}_total_metrics.png"
    api_out = out_dir / f"{args.prefix}_api_goodput.png"

    plot_total(total_rows, total_out)
    plot_api_goodput(logs_dir, apis, api_out)

    print(f"logs_dir={logs_dir}")
    print(f"saved={total_out}")
    print(f"saved={api_out}")


if __name__ == "__main__":
    main()

