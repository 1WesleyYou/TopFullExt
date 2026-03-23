"""
BACA-Lite: Bottleneck-aware heuristic controller (G2 upper bound).

Minimal-invasive behavior:
- Reuse Collector + apply_threshold_proxy channel.
- Reuse .env gate window (NET_INJECT_AT_SEC / NET_RELEASE_AT_SEC).
- Keep API-weighted budgeting logic, but avoid "slow-then-overkill" behavior:
  1) Use pre-window baseline as budget base.
  2) Warm-start thresholds when entering gate window.
  3) Temporarily relax slew-rate in first few control rounds.
"""

import csv
import json
import os
import time
from typing import Dict, List, Tuple

import requests

from metric_collector import Collector
from overload_detection import apply_threshold_proxy


Metric = Dict[str, Tuple[float, float, float, float]]
ThresholdMap = Dict[str, float]


def _read_env_file() -> Dict[str, str]:
    env_path = os.path.expanduser("~/TopFullExt/.env")
    result: Dict[str, str] = {}
    if os.path.isfile(env_path):
        with open(env_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                result[key.strip()] = value.strip()
    return result


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def compute_severity(metric: Metric) -> float:
    total_rps = sum(m[0] for m in metric.values())
    total_fail = sum(m[1] for m in metric.values())
    max_l95 = max((m[2] for m in metric.values()), default=0.0)
    fail_ratio = total_fail / total_rps if total_rps > 0 else 0.0
    lat_score = min(max_l95 / 5000.0, 1.0)
    return 0.75 * fail_ratio + 0.25 * lat_score


def budget_factor(severity: float) -> float:
    return max(0.60, 1.0 - 0.6 * severity)


def current_rps(proxy_url: str) -> Dict[str, float]:
    proxies = {"http": proxy_url}
    url = proxy_url + "/stats"
    result: Dict[str, float] = {}
    try:
        response = requests.get(url, proxies=proxies, timeout=3)
        if response.ok:
            for elem in response.text.split("/")[:-1]:
                parts = elem.split("=")
                if len(parts) == 2:
                    result[parts[0]] = float(parts[1])
    except Exception:
        pass
    return result


def apply_thresholds(thresholds: ThresholdMap) -> None:
    payload = [{"name": api, "threshold": value} for api, value in thresholds.items()]
    apply_threshold_proxy(payload)


def api_rps(api: str, metric: Metric, rps: Dict[str, float]) -> float:
    # Prefer proxy-side observed RPS; fallback to collector value.
    if api in rps:
        return float(rps.get(api, 0.0))
    return float(metric.get(api, (0.0, 0.0, 0.0, 0.0))[0])


global_config_path = os.path.expanduser(
    "~/TopFullExt/TopFull_master/online_boutique_scripts/src/global_config.json"
)
with open(global_config_path, "r") as f:
    global_config = json.load(f)
global_config = {
    k: os.path.expandvars(os.path.expanduser(v)) if isinstance(v, str) else v
    for k, v in global_config.items()
}

_dot_env = _read_env_file()
GATE_START = int(os.environ.get("NET_INJECT_AT_SEC", _dot_env.get("NET_INJECT_AT_SEC", "0")))
GATE_END = int(os.environ.get("NET_RELEASE_AT_SEC", _dot_env.get("NET_RELEASE_AT_SEC", "0")))
BOTTLENECK_SVC = os.environ.get(
    "BACA_BOTTLENECK",
    _dot_env.get("NET_TARGET_SELECTOR", "app=productcatalogservice").split("=")[-1],
)

with open(global_config["microservice_configuration"], "r") as f:
    topo = json.load(f)

ALL_APIS: List[str] = [a["name"] for a in topo["data"]["api"]]
AFFECTED_APIS: List[str] = [a["name"] for a in topo["data"]["api"] if BOTTLENECK_SVC in a["execution_path"]]
SAFE_APIS: List[str] = [a for a in ALL_APIS if a not in AFFECTED_APIS]

WEIGHTS: Dict[str, float] = {
    "postcheckout": 4.0,
    "getcart": 3.0,
    "getproduct": 2.0,
    "postcart": 1.0,
}

HIGH_THRESHOLD = 10000.0
MIN_THRESHOLD = 10.0
NORMAL_SLEW_RATE = 0.15
FAST_SLEW_RATE = 0.45
FAST_SLEW_CYCLES = 6
INTERVAL_S = 2

collector = Collector(code=global_config["microservice_code"])
log_path = global_config["record_path"]
os.makedirs(log_path, exist_ok=True)

num_agent_path = os.path.join(log_path, "num_agent.csv")
if os.path.exists(num_agent_path):
    os.remove(num_agent_path)

prev_thresholds: ThresholdMap = {api: HIGH_THRESHOLD for api in ALL_APIS}
loop_start = time.time()
was_in_window = False
gate_closed = False
fast_slew_left = 0
pre_window_baseline = 0.0
pre_window_per_api: ThresholdMap = {api: 0.0 for api in ALL_APIS}

print("[baca] BACA-Lite started")
print(f"[baca] bottleneck service: {BOTTLENECK_SVC}")
print(f"[baca] affected APIs: {AFFECTED_APIS}")
print(f"[baca] safe APIs: {SAFE_APIS}")
print(f"[baca] enabled: window [{GATE_START}s, {GATE_END}s]")

while True:
    time.sleep(INTERVAL_S)
    elapsed = time.time() - loop_start
    in_window = GATE_END > GATE_START > 0 and GATE_START <= elapsed <= GATE_END

    metric = collector.query()
    rps = current_rps(global_config["proxy_url"])
    current_total = sum(api_rps(api, metric, rps) for api in AFFECTED_APIS)

    # Capture baseline capacity before entering gate window.
    if not in_window and elapsed < GATE_START and current_total > 0:
        pre_window_baseline = max(pre_window_baseline, current_total)
        for a in ALL_APIS:
            r = api_rps(a, metric, rps)
            pre_window_per_api[a] = max(pre_window_per_api[a], r)

    with open(num_agent_path, "a") as f:
        csv.writer(f).writerow([1 if in_window else 0])

    if not in_window:
        if not gate_closed and elapsed > GATE_END > 0:
            reset = {api: HIGH_THRESHOLD for api in ALL_APIS}
            apply_thresholds(reset)
            prev_thresholds = dict(reset)
            gate_closed = True
            print(f"[baca] t={elapsed:.0f}s window closed, resetting thresholds to {int(HIGH_THRESHOLD)}")
        elif elapsed < GATE_START:
            print(
                f"[baca] t={elapsed:.0f}s waiting for window "
                f"(starts at {GATE_START}s, baseline={pre_window_baseline:.1f})"
            )
        was_in_window = False
        continue

    if not metric:
        print(f"[baca] t={elapsed:.0f}s no metrics available, skip")
        was_in_window = True
        continue

    if not was_in_window:
        # Warm-start: avoid being constrained by 10000 -> target via slew decay.
        for api in AFFECTED_APIS:
            prev_thresholds[api] = max(api_rps(api, metric, rps), MIN_THRESHOLD)
        for api in SAFE_APIS:
            prev_thresholds[api] = HIGH_THRESHOLD
        if pre_window_baseline <= 0:
            pre_window_baseline = max(current_total, 1.0)
        fast_slew_left = FAST_SLEW_CYCLES
        gate_closed = False
        print(
            f"[baca] t={elapsed:.0f}s entering window, "
            f"warm-start baseline={pre_window_baseline:.1f}, fast_slew={FAST_SLEW_CYCLES}"
        )

    severity = compute_severity(metric)
    k_value = budget_factor(severity)
    budget_base = max(pre_window_baseline, current_total, 1.0)
    budget = budget_base * k_value

    active_affected = [api for api in AFFECTED_APIS if api_rps(api, metric, rps) > 0]
    w_sum = sum(WEIGHTS.get(api, 1.0) for api in active_affected)
    slew_rate = FAST_SLEW_RATE if fast_slew_left > 0 else NORMAL_SLEW_RATE

    new_thresholds: ThresholdMap = {}
    FLOOR_RATIO = 0.50
    for api in AFFECTED_APIS:
        curr = api_rps(api, metric, rps)
        floor = max(pre_window_per_api.get(api, 0.0) * FLOOR_RATIO, MIN_THRESHOLD)
        if w_sum > 0 and api in active_affected:
            share = (WEIGHTS.get(api, 1.0) / w_sum) * budget
        else:
            share = floor
        raw = clamp(share, floor, curr * 1.1 if curr > 0 else HIGH_THRESHOLD)
        lower = prev_thresholds[api] * (1 - slew_rate)
        upper = prev_thresholds[api] * (1 + slew_rate)
        new_thresholds[api] = max(clamp(raw, lower, upper), floor)

    for api in SAFE_APIS:
        curr = api_rps(api, metric, rps)
        new_thresholds[api] = max(curr * 1.1, HIGH_THRESHOLD)

    apply_thresholds(new_thresholds)
    prev_thresholds = dict(new_thresholds)
    fast_slew_left = max(0, fast_slew_left - 1)
    was_in_window = True

    thr_str = " ".join(f"{api}={new_thresholds[api]:.1f}" for api in ALL_APIS if api in new_thresholds)
    print(
        f"[baca] t={elapsed:.0f}s severity={severity:.3f} k={k_value:.2f} "
        f"budget={budget:.1f} base={budget_base:.1f} slew={slew_rate:.2f} | {thr_str}"
    )
