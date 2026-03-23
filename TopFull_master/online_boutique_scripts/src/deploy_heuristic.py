import csv
import json
import os
import time
import urllib.request

from metric_collector import Collector
from overload_detection import apply_threshold_proxy


global_config_path = os.path.expanduser(
    "~/TopFullExt/TopFull_master/online_boutique_scripts/src/global_config.json"
)
with open(global_config_path, "r") as f:
    global_config = json.load(f)
global_config = {
    k: os.path.expandvars(os.path.expanduser(v)) if isinstance(v, str) else v
    for k, v in global_config.items()
}


def _read_env_file():
    env_path = os.path.expanduser("~/TopFullExt/.env")
    d = {}
    if os.path.isfile(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip()
    return d


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def compute_severity(metric):
    total_rps = sum(m[0] for m in metric.values())
    total_fail = sum(m[1] for m in metric.values())
    max_l95 = max((m[2] for m in metric.values()), default=0.0)
    fail_ratio = total_fail / total_rps if total_rps > 0 else 0.0
    lat_score = min(max_l95 / 5000.0, 1.0)
    return 0.6 * fail_ratio + 0.4 * lat_score


def k_of(severity):
    return max(0.35, 1.0 - 0.8 * severity)


def current_rps():
    url = global_config["proxy_url"] + "/stats"
    result = {}
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            body = resp.read().decode("utf-8")
        for elem in body.split("/")[:-1]:
            parts = elem.split("=")
            if len(parts) == 2:
                result[parts[0]] = float(parts[1])
    except Exception:
        return {}
    return result


def apply_thresholds(thresholds):
    apis = []
    for name, threshold in thresholds.items():
        apis.append({"name": name, "threshold": float(threshold)})
    apply_threshold_proxy(apis)


_dot_env = _read_env_file()
GATE_START = int(os.environ.get("NET_INJECT_AT_SEC", _dot_env.get("NET_INJECT_AT_SEC", "0")))
GATE_END = int(os.environ.get("NET_RELEASE_AT_SEC", _dot_env.get("NET_RELEASE_AT_SEC", "0")))

AFFECTED_APIS = ["getproduct", "getcart", "postcart", "postcheckout"]
SAFE_APIS = ["emptycart"]
ALL_APIS = AFFECTED_APIS + SAFE_APIS
WEIGHTS = {"postcheckout": 4, "getcart": 3, "getproduct": 2, "postcart": 1}

HIGH_THRESHOLD = 10000.0
MIN_THRESHOLD = 10.0
SLEW = 0.15


collector = Collector(code=global_config["microservice_code"])
log_path = global_config["record_path"]
os.makedirs(log_path, exist_ok=True)
num_agent_file = os.path.join(log_path, "num_agent.csv")
if os.path.exists(num_agent_file):
    os.remove(num_agent_file)

prev_thresholds = {api: HIGH_THRESHOLD for api in ALL_APIS}
loop_start = time.time()
window_closed_logged = False

print(f"[baca] enabled: window [{GATE_START}s, {GATE_END}s]")

while True:
    time.sleep(2)
    elapsed = time.time() - loop_start
    in_window = GATE_END > GATE_START > 0 and GATE_START <= elapsed <= GATE_END

    with open(num_agent_file, "a") as f:
        w = csv.writer(f)
        w.writerow([1 if in_window else 0])

    if not in_window:
        if not window_closed_logged and elapsed > GATE_END > 0:
            reset_thresholds = {api: HIGH_THRESHOLD for api in ALL_APIS}
            apply_thresholds(reset_thresholds)
            prev_thresholds = reset_thresholds
            print(f"[baca] t={elapsed:.0f}s window closed, resetting thresholds to {int(HIGH_THRESHOLD)}")
            window_closed_logged = True
        continue

    metric = collector.query()
    rps = current_rps()
    if not metric:
        continue

    total_baseline = sum(rps.get(a, metric.get(a, (0.0, 0.0, 0.0, 0.0))[0]) for a in AFFECTED_APIS)
    severity = compute_severity(metric)
    budget = total_baseline * k_of(severity)

    active_apis = [a for a in AFFECTED_APIS if rps.get(a, metric.get(a, (0.0, 0.0, 0.0, 0.0))[0]) > 0]
    w_sum = sum(WEIGHTS[a] for a in active_apis)

    thresholds = {}
    for api in AFFECTED_APIS:
        curr_rps = rps.get(api, metric.get(api, (0.0, 0.0, 0.0, 0.0))[0])
        if w_sum > 0 and api in active_apis:
            share = WEIGHTS[api] / w_sum * budget
        else:
            share = MIN_THRESHOLD
        raw = clamp(share, MIN_THRESHOLD, max(curr_rps * 1.1, MIN_THRESHOLD))
        low = prev_thresholds[api] * (1 - SLEW)
        high = prev_thresholds[api] * (1 + SLEW)
        thresholds[api] = clamp(raw, low, high)

    for api in SAFE_APIS:
        curr_rps = rps.get(api, metric.get(api, (0.0, 0.0, 0.0, 0.0))[0])
        thresholds[api] = max(curr_rps * 1.1, HIGH_THRESHOLD)

    apply_thresholds(thresholds)
    prev_thresholds = thresholds

    print(f"[baca] t={elapsed:.0f}s severity={severity:.3f} budget={budget:.1f} api_thresholds={thresholds}")
"""
BACA-Lite: Bottleneck-Aware Capacity Allocation (heuristic G2 upper-bound controller).

Directionally throttles APIs that traverse a degraded service (e.g. productcatalogservice)
while leaving unaffected APIs (e.g. emptycart) at full capacity.

Uses the same proxy threshold channel as TopFull RL (apply_threshold_proxy + SIGUSR1).
"""

import json
import os
import time
import csv
import subprocess
import requests

from metric_collector import Collector
from overload_detection import apply_threshold_proxy

# ── Config ──────────────────────────────────────────────────────────────

global_config_path = os.path.expanduser(
    "~/TopFullExt/TopFull_master/online_boutique_scripts/src/global_config.json"
)
with open(global_config_path, "r") as f:
    global_config = json.load(f)
global_config = {
    k: os.path.expandvars(os.path.expanduser(v)) if isinstance(v, str) else v
    for k, v in global_config.items()
}


def _read_env_file():
    env_path = os.path.expanduser("~/TopFullExt/.env")
    d = {}
    if os.path.isfile(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip()
    return d


_dot_env = _read_env_file()
GATE_START = int(os.environ.get("NET_INJECT_AT_SEC", _dot_env.get("NET_INJECT_AT_SEC", "0")))
GATE_END = int(os.environ.get("NET_RELEASE_AT_SEC", _dot_env.get("NET_RELEASE_AT_SEC", "0")))

BOTTLENECK_SVC = os.environ.get(
    "BACA_BOTTLENECK",
    _dot_env.get("NET_TARGET_SELECTOR", "app=productcatalogservice").split("=")[-1],
)

# ── Topology: derive affected / safe APIs from online_boutique.json ─────

with open(global_config["microservice_configuration"], "r") as f:
    _topo = json.load(f)

ALL_APIS = [a["name"] for a in _topo["data"]["api"]]
AFFECTED_APIS = [
    a["name"]
    for a in _topo["data"]["api"]
    if BOTTLENECK_SVC in a["execution_path"]
]
SAFE_APIS = [a for a in ALL_APIS if a not in AFFECTED_APIS]

WEIGHTS = {
    "postcheckout": 4,
    "getcart": 3,
    "getproduct": 2,
    "postcart": 1,
}

HIGH_THRESHOLD = 10000
MIN_THRESHOLD = 10
SLEW_RATE = 0.15
INTERVAL_S = 2

# ── Helpers ──────────────────────────────────────────────────────────────


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def compute_severity(metric: dict) -> float:
    total_rps = sum(m[0] for m in metric.values())
    total_fail = sum(m[1] for m in metric.values())
    max_l95 = max((m[2] for m in metric.values()), default=0)
    fail_ratio = total_fail / total_rps if total_rps > 0 else 0.0
    lat_score = min(max_l95 / 5000.0, 1.0)
    return 0.6 * fail_ratio + 0.4 * lat_score


def budget_factor(severity: float) -> float:
    return max(0.35, 1.0 - 0.8 * severity)


def current_rps() -> dict:
    proxies = {"http": global_config["proxy_url"]}
    url = global_config["proxy_url"] + "/stats"
    result = {}
    try:
        resp = requests.get(url, proxies=proxies, timeout=3)
        if resp.ok:
            for elem in resp.text.split("/")[:-1]:
                parts = elem.split("=")
                if len(parts) == 2:
                    result[parts[0]] = float(parts[1])
    except Exception:
        pass
    return result


def apply_thresholds(thresholds: dict):
    apis_payload = []
    for name, thr in thresholds.items():
        apis_payload.append({"name": name, "threshold": thr})
    apply_threshold_proxy(apis_payload)


# ── Main loop ────────────────────────────────────────────────────────────

collector = Collector(code=global_config["microservice_code"])
log_path = global_config["record_path"]
if os.path.exists(log_path + "num_agent.csv"):
    os.remove(log_path + "num_agent.csv")

prev_thresholds = {api: HIGH_THRESHOLD for api in ALL_APIS}
gate_closed = False
loop_start = time.time()

print(f"[baca] BACA-Lite started")
print(f"[baca] bottleneck service: {BOTTLENECK_SVC}")
print(f"[baca] affected APIs: {AFFECTED_APIS}")
print(f"[baca] safe APIs: {SAFE_APIS}")
if GATE_END > GATE_START > 0:
    print(f"[baca] enabled: window [{GATE_START}s, {GATE_END}s]")
else:
    print(f"[baca] WARNING: gate window not configured (start={GATE_START}, end={GATE_END})")

while True:
    time.sleep(INTERVAL_S)
    elapsed = time.time() - loop_start
    in_window = GATE_END > GATE_START > 0 and GATE_START <= elapsed <= GATE_END

    with open(log_path + "num_agent.csv", "a") as f:
        csv.writer(f).writerow([1 if in_window else 0])

    if not in_window:
        if not gate_closed and elapsed > GATE_END > 0:
            print(f"[baca] t={elapsed:.0f}s window closed, resetting thresholds to {HIGH_THRESHOLD}")
            gate_closed = True
            for api in ALL_APIS:
                prev_thresholds[api] = HIGH_THRESHOLD
            apply_thresholds(prev_thresholds)
        elif not gate_closed:
            print(f"[baca] t={elapsed:.0f}s waiting for window (starts at {GATE_START}s)")
        continue

    metric = collector.query()
    rps = current_rps()

    if not metric or not rps:
        print(f"[baca] t={elapsed:.0f}s no metrics available, skip")
        continue

    severity = compute_severity(metric)
    k = budget_factor(severity)
    total_baseline = sum(rps.get(a, 0) for a in AFFECTED_APIS)
    budget = total_baseline * k

    active_affected = [a for a in AFFECTED_APIS if rps.get(a, 0) > 0]
    w_sum = sum(WEIGHTS.get(a, 1) for a in active_affected)

    new_thresholds = {}

    for api in AFFECTED_APIS:
        if w_sum > 0 and api in active_affected:
            share = WEIGHTS.get(api, 1) / w_sum * budget
        else:
            share = MIN_THRESHOLD
        raw = clamp(share, MIN_THRESHOLD, rps.get(api, 0) * 1.1 if rps.get(api, 0) > 0 else HIGH_THRESHOLD)
        damped = clamp(raw, prev_thresholds[api] * (1 - SLEW_RATE), prev_thresholds[api] * (1 + SLEW_RATE))
        new_thresholds[api] = max(damped, MIN_THRESHOLD)

    for api in SAFE_APIS:
        new_thresholds[api] = max(rps.get(api, 0) * 1.1, HIGH_THRESHOLD)

    apply_thresholds(new_thresholds)
    prev_thresholds = dict(new_thresholds)

    thr_str = " ".join(f"{a}={new_thresholds[a]:.0f}" for a in ALL_APIS if a in new_thresholds)
    print(f"[baca] t={elapsed:.0f}s severity={severity:.3f} k={k:.2f} budget={budget:.0f} | {thr_str}")
