"""
HEU-C: timeout-aware bottleneck heuristic.

This file intentionally updates the existing heuristic implementation in-place.
No new controller script is introduced.
"""

import csv
import json
import os
import time
from typing import Dict, List, Set, Tuple

import requests

from metric_collector import Collector
from overload_detection import apply_threshold_proxy


Metric = Dict[str, Tuple[float, float, float, float]]
FailStats = Dict[str, Tuple[float, float, float, float]]  # total_rps, reject_rps, accept_rps, reject_ratio
ThresholdMap = Dict[str, float]
ApiSignal = Dict[str, float]

MODE_NORMAL = "NORMAL"
MODE_PROTECTIVE = "PROTECTIVE"
MODE_EMERGENCY = "EMERGENCY"
MODE_RECOVERY = "RECOVERY"


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


def _env_float(name: str, env_map: Dict[str, str], default: float) -> float:
    raw = os.environ.get(name, env_map.get(name))
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_int(name: str, env_map: Dict[str, str], default: int) -> int:
    raw = os.environ.get(name, env_map.get(name))
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_bool(name: str, env_map: Dict[str, str], default: bool) -> bool:
    raw = os.environ.get(name, env_map.get(name))
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def normalize_positive(values: Dict[str, float]) -> Dict[str, float]:
    total = sum(max(v, 0.0) for v in values.values())
    if total <= 0:
        return {k: 0.0 for k in values}
    return {k: max(v, 0.0) / total for k, v in values.items()}


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


def build_api_signal(
    api: str,
    metric: Metric,
    rps_map: Dict[str, float],
    fail_stats: FailStats,
    baseline_rps: float,
    target_latency_ms: float,
) -> ApiSignal:
    m = metric.get(api, (0.0, 0.0, 0.0, 0.0))
    rps = float(api_rps(api, metric, rps_map))
    fail = float(m[1])
    l95 = float(m[2])
    proxy_total, proxy_reject, _, _ = fail_stats.get(api, (0.0, 0.0, 0.0, 0.0))
    reject = min(max(proxy_reject, 0.0), fail)
    timeout_est = max(fail - reject, 0.0)
    drop = 0.0
    if baseline_rps > 0:
        drop = clamp(1.0 - rps / baseline_rps, 0.0, 1.0)
    lat_excess = max(0.0, l95 / max(target_latency_ms, 1.0) - 1.0)
    return {
        "rps": rps,
        "fail": fail,
        "l95": l95,
        "reject": reject,
        "timeout_est": timeout_est,
        "drop": drop,
        "lat_excess": lat_excess,
        "proxy_total_rps": proxy_total,
    }


def next_mode(
    current_mode: str,
    severity: float,
    timeout_share: float,
    l95_max: float,
    counters: Dict[str, int],
    conf: Dict[str, float],
) -> Tuple[str, str]:
    if current_mode == MODE_NORMAL:
        if severity > conf["SEVERITY_ENTER_PROTECT"]:
            counters["normal_to_protect"] += 1
        else:
            counters["normal_to_protect"] = 0
        if counters["normal_to_protect"] >= int(conf["CNT_ENTER_PROTECT"]):
            return MODE_PROTECTIVE, "severity_enter"

    elif current_mode == MODE_PROTECTIVE:
        emergency_cond = timeout_share > conf["TIMEOUT_ENTER_EMERGENCY"] or l95_max > conf["LAT_ENTER_EMERGENCY_MS"]
        if emergency_cond:
            counters["protect_to_emergency"] += 1
        else:
            counters["protect_to_emergency"] = 0
        if counters["protect_to_emergency"] >= int(conf["CNT_ENTER_EMERGENCY"]):
            return MODE_EMERGENCY, "timeout_or_latency_spike"
        if severity < conf["SEVERITY_RECOVER_TO_NORMAL"]:
            counters["protect_to_normal"] += 1
        else:
            counters["protect_to_normal"] = 0
        if counters["protect_to_normal"] >= int(conf["CNT_PROTECT_TO_NORMAL"]):
            return MODE_NORMAL, "severity_recovered"

    elif current_mode == MODE_EMERGENCY:
        recover_cond = timeout_share < conf["TIMEOUT_EXIT_EMERGENCY"] and l95_max < conf["LAT_EXIT_EMERGENCY_MS"]
        if recover_cond:
            counters["emergency_to_recovery"] += 1
        else:
            counters["emergency_to_recovery"] = 0
        if counters["emergency_to_recovery"] >= int(conf["CNT_EXIT_EMERGENCY"]):
            return MODE_RECOVERY, "timeout_latency_recovered"

    elif current_mode == MODE_RECOVERY:
        if severity < conf["SEVERITY_RECOVER_TO_NORMAL"]:
            counters["recovery_to_normal"] += 1
        else:
            counters["recovery_to_normal"] = 0
        if counters["recovery_to_normal"] >= int(conf["CNT_RECOVERY_TO_NORMAL"]):
            return MODE_NORMAL, "stable_recovery"
        if severity > conf["SEVERITY_RECOVERY_TO_PROTECT"]:
            counters["recovery_to_protect"] += 1
        else:
            counters["recovery_to_protect"] = 0
        if counters["recovery_to_protect"] >= int(conf["CNT_RECOVERY_TO_PROTECT"]):
            return MODE_PROTECTIVE, "rebound_detected"

    return current_mode, ""


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

# Business weights for affected APIs.
WEIGHTS: Dict[str, float] = {
    "postcheckout": _env_float("BACA_WEIGHT_POSTCHECKOUT", _dot_env, 4.0),
    "getcart": _env_float("BACA_WEIGHT_GETCART", _dot_env, 3.0),
    "getproduct": _env_float("BACA_WEIGHT_GETPRODUCT", _dot_env, 2.0),
    "postcart": _env_float("BACA_WEIGHT_POSTCART", _dot_env, 1.0),
}
# Priority APIs to protect first under degradation (always-on policy).
PRIORITY_CANDIDATES: Tuple[str, str] = ("getcart", "getproduct")
PRIORITY_APIS: List[str] = [api for api in PRIORITY_CANDIDATES if api in AFFECTED_APIS]
NON_PRIORITY_APIS: List[str] = [a for a in AFFECTED_APIS if a not in PRIORITY_APIS]

HEUC_ENABLE = _env_bool("BACA_HEUC_ENABLE", _dot_env, True)
HIGH_THRESHOLD = _env_float("BACA_HIGH_THRESHOLD", _dot_env, 10000.0)
MIN_THRESHOLD = _env_float("BACA_MIN_THRESHOLD", _dot_env, 10.0)
TARGET_LATENCY_MS = _env_float("BACA_TARGET_LATENCY_MS", _dot_env, 900.0)
INTERVAL_S = _env_int("BACA_INTERVAL_S", _dot_env, 2)

# Severity and budget coefficients.
SEV_W_FAIL = _env_float("BACA_SEV_W_FAIL", _dot_env, 0.45)
SEV_W_LAT = _env_float("BACA_SEV_W_LAT", _dot_env, 0.25)
SEV_W_TIMEOUT = _env_float("BACA_SEV_W_TIMEOUT", _dot_env, 0.30)
BUDGET_A = _env_float("BACA_BUDGET_A", _dot_env, 0.75)
BUDGET_B = _env_float("BACA_BUDGET_B", _dot_env, 0.45)
K_MIN = _env_float("BACA_HEUC_K_MIN", _dot_env, _env_float("BACA_MIN_BUDGET_FACTOR", _dot_env, 0.18))

# Urgency coefficients for stage-B allocation.
URG_ALPHA_TIMEOUT = _env_float("BACA_URG_ALPHA_TIMEOUT", _dot_env, 0.55)
URG_BETA_LAT = _env_float("BACA_URG_BETA_LAT", _dot_env, 0.25)
URG_GAMMA_DROP = _env_float("BACA_URG_GAMMA_DROP", _dot_env, 0.20)

# Mode transition thresholds and dwell counters.
MODE_CONF: Dict[str, float] = {
    "SEVERITY_ENTER_PROTECT": _env_float("BACA_SEVERITY_ENTER_PROTECT", _dot_env, 0.40),
    "TIMEOUT_ENTER_EMERGENCY": _env_float("BACA_TIMEOUT_ENTER_EMERGENCY", _dot_env, 0.20),
    "LAT_ENTER_EMERGENCY_MS": _env_float("BACA_LAT_ENTER_EMERGENCY_MS", _dot_env, 1800.0),
    "TIMEOUT_EXIT_EMERGENCY": _env_float("BACA_TIMEOUT_EXIT_EMERGENCY", _dot_env, 0.08),
    "LAT_EXIT_EMERGENCY_MS": _env_float("BACA_LAT_EXIT_EMERGENCY_MS", _dot_env, 1000.0),
    "SEVERITY_RECOVER_TO_NORMAL": _env_float("BACA_SEVERITY_RECOVER_TO_NORMAL", _dot_env, 0.25),
    "SEVERITY_RECOVERY_TO_PROTECT": _env_float("BACA_SEVERITY_RECOVERY_TO_PROTECT", _dot_env, 0.45),
    "CNT_ENTER_PROTECT": float(_env_int("BACA_CNT_ENTER_PROTECT", _dot_env, 2)),
    "CNT_ENTER_EMERGENCY": float(_env_int("BACA_CNT_ENTER_EMERGENCY", _dot_env, 2)),
    "CNT_EXIT_EMERGENCY": float(_env_int("BACA_CNT_EXIT_EMERGENCY", _dot_env, 6)),
    "CNT_RECOVERY_TO_NORMAL": float(_env_int("BACA_CNT_RECOVERY_TO_NORMAL", _dot_env, 10)),
    "CNT_RECOVERY_TO_PROTECT": float(_env_int("BACA_CNT_RECOVERY_TO_PROTECT", _dot_env, 2)),
    "CNT_PROTECT_TO_NORMAL": float(_env_int("BACA_CNT_PROTECT_TO_NORMAL", _dot_env, 4)),
}

FLOOR_BY_MODE = {
    MODE_NORMAL: _env_float("BACA_FLOOR_NORMAL", _dot_env, _env_float("BACA_FLOOR_RATIO_BASE", _dot_env, 0.30)),
    MODE_PROTECTIVE: _env_float("BACA_FLOOR_PROTECTIVE", _dot_env, 0.20),
    MODE_EMERGENCY: _env_float("BACA_FLOOR_EMERGENCY", _dot_env, _env_float("BACA_FLOOR_RATIO_EMERGENCY", _dot_env, 0.08)),
    MODE_RECOVERY: _env_float("BACA_FLOOR_RECOVERY", _dot_env, 0.25),
}
SLEW_BY_MODE = {
    MODE_NORMAL: _env_float("BACA_SLEW_NORMAL", _dot_env, _env_float("BACA_NORMAL_SLEW_RATE", _dot_env, 0.20)),
    MODE_PROTECTIVE: _env_float("BACA_SLEW_PROTECTIVE", _dot_env, 0.45),
    MODE_EMERGENCY: _env_float("BACA_SLEW_EMERGENCY", _dot_env, _env_float("BACA_EMERGENCY_SLEW_RATE", _dot_env, 0.85)),
    MODE_RECOVERY: _env_float("BACA_SLEW_RECOVERY", _dot_env, 0.18),
}
SHOCK_CYCLES = _env_int("BACA_SHOCK_CYCLES", _dot_env, 3)
SHOCK_FACTOR = _env_float("BACA_SHOCK_FACTOR", _dot_env, 0.68)

# Priority allocation controls (medium-intrusion policy).
PRIORITY_RESERVE_BY_MODE = {
    MODE_NORMAL: _env_float("BACA_PRIORITY_RESERVE_NORMAL", _dot_env, 0.25),
    MODE_PROTECTIVE: _env_float("BACA_PRIORITY_RESERVE_PROTECTIVE", _dot_env, 0.40),
    MODE_EMERGENCY: _env_float("BACA_PRIORITY_RESERVE_EMERGENCY", _dot_env, 0.60),
    MODE_RECOVERY: _env_float("BACA_PRIORITY_RESERVE_RECOVERY", _dot_env, 0.45),
}
PRIORITY_FLOOR_MULT_BY_MODE = {
    MODE_NORMAL: _env_float("BACA_PRIORITY_FLOOR_MULT_NORMAL", _dot_env, 1.15),
    MODE_PROTECTIVE: _env_float("BACA_PRIORITY_FLOOR_MULT_PROTECTIVE", _dot_env, 1.30),
    MODE_EMERGENCY: _env_float("BACA_PRIORITY_FLOOR_MULT_EMERGENCY", _dot_env, 1.55),
    MODE_RECOVERY: _env_float("BACA_PRIORITY_FLOOR_MULT_RECOVERY", _dot_env, 1.35),
}
PRIORITY_URG_MULT_BY_MODE = {
    MODE_NORMAL: _env_float("BACA_PRIORITY_URG_MULT_NORMAL", _dot_env, 1.20),
    MODE_PROTECTIVE: _env_float("BACA_PRIORITY_URG_MULT_PROTECTIVE", _dot_env, 1.60),
    MODE_EMERGENCY: _env_float("BACA_PRIORITY_URG_MULT_EMERGENCY", _dot_env, 2.20),
    MODE_RECOVERY: _env_float("BACA_PRIORITY_URG_MULT_RECOVERY", _dot_env, 1.80),
}
NON_PRIORITY_MAX_SHARE_BY_MODE = {
    MODE_NORMAL: _env_float("BACA_NON_PRIORITY_MAX_SHARE_NORMAL", _dot_env, 1.00),
    MODE_PROTECTIVE: _env_float("BACA_NON_PRIORITY_MAX_SHARE_PROTECTIVE", _dot_env, 0.60),
    MODE_EMERGENCY: _env_float("BACA_NON_PRIORITY_MAX_SHARE_EMERGENCY", _dot_env, 0.20),
    MODE_RECOVERY: _env_float("BACA_NON_PRIORITY_MAX_SHARE_RECOVERY", _dot_env, 0.45),
}
RECOVERY_HOLD_CYCLES = _env_int("BACA_RECOVERY_HOLD_CYCLES", _dot_env, 6)
RECOVERY_HOLD_NON_PRIORITY_CAP = _env_float("BACA_RECOVERY_HOLD_NON_PRIORITY_CAP", _dot_env, 0.10)

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
pre_window_baseline = 0.0
pre_window_per_api: ThresholdMap = {api: 0.0 for api in ALL_APIS}
mode = MODE_NORMAL
mode_counters = {
    "normal_to_protect": 0,
    "protect_to_emergency": 0,
    "protect_to_normal": 0,
    "emergency_to_recovery": 0,
    "recovery_to_normal": 0,
    "recovery_to_protect": 0,
}
shock_left = 0
recovery_hold_left = 0

print("[heuc] HEU-C started")
print(f"[heuc] bottleneck service: {BOTTLENECK_SVC}")
print(f"[heuc] affected APIs: {AFFECTED_APIS}")
print(f"[heuc] safe APIs: {SAFE_APIS}")
print(f"[heuc] priority APIs: {PRIORITY_APIS}, non-priority APIs: {NON_PRIORITY_APIS}")
print(f"[heuc] enabled: window [{GATE_START}s, {GATE_END}s], heuc_enable={HEUC_ENABLE}")
print(
    "[heuc] params: "
    f"target_l95={TARGET_LATENCY_MS:.0f}ms, k_min={K_MIN:.2f}, "
    f"floor(N/P/E/R)=({FLOOR_BY_MODE[MODE_NORMAL]:.2f}/{FLOOR_BY_MODE[MODE_PROTECTIVE]:.2f}/"
    f"{FLOOR_BY_MODE[MODE_EMERGENCY]:.2f}/{FLOOR_BY_MODE[MODE_RECOVERY]:.2f}), "
    f"slew(N/P/E/R)=({SLEW_BY_MODE[MODE_NORMAL]:.2f}/{SLEW_BY_MODE[MODE_PROTECTIVE]:.2f}/"
    f"{SLEW_BY_MODE[MODE_EMERGENCY]:.2f}/{SLEW_BY_MODE[MODE_RECOVERY]:.2f}), "
    f"prio_reserve(N/P/E/R)=({PRIORITY_RESERVE_BY_MODE[MODE_NORMAL]:.2f}/{PRIORITY_RESERVE_BY_MODE[MODE_PROTECTIVE]:.2f}/"
    f"{PRIORITY_RESERVE_BY_MODE[MODE_EMERGENCY]:.2f}/{PRIORITY_RESERVE_BY_MODE[MODE_RECOVERY]:.2f}), "
    f"shock(cycles={SHOCK_CYCLES},factor={SHOCK_FACTOR:.2f})"
)

while True:
    time.sleep(INTERVAL_S)
    elapsed = time.time() - loop_start
    in_window = GATE_END > GATE_START > 0 and GATE_START <= elapsed <= GATE_END

    metric = collector.query()
    rps_map = current_rps(global_config["proxy_url"])
    fail_stats = collector.query_proxy_failstats()
    current_total = sum(api_rps(api, metric, rps_map) for api in AFFECTED_APIS)

    # Capture pre-window healthy baseline.
    if not in_window and elapsed < GATE_START and current_total > 0:
        pre_window_baseline = max(pre_window_baseline, current_total)
        for api in ALL_APIS:
            pre_window_per_api[api] = max(pre_window_per_api[api], api_rps(api, metric, rps_map))

    with open(num_agent_path, "a") as f:
        csv.writer(f).writerow([1 if in_window else 0])

    if not in_window:
        if not gate_closed and elapsed > GATE_END > 0:
            reset = {api: HIGH_THRESHOLD for api in ALL_APIS}
            apply_thresholds(reset)
            prev_thresholds = dict(reset)
            gate_closed = True
            mode = MODE_NORMAL
            shock_left = 0
            for k in mode_counters:
                mode_counters[k] = 0
            print(f"[heuc] t={elapsed:.0f}s window closed, resetting thresholds to {int(HIGH_THRESHOLD)}")
        elif elapsed < GATE_START:
            print(f"[heuc] t={elapsed:.0f}s waiting for window (starts at {GATE_START}s, baseline={pre_window_baseline:.1f})")
        was_in_window = False
        continue

    if not metric:
        print(f"[heuc] t={elapsed:.0f}s no metrics available, skip")
        was_in_window = True
        continue

    if not was_in_window:
        for api in AFFECTED_APIS:
            prev_thresholds[api] = max(api_rps(api, metric, rps_map), MIN_THRESHOLD)
        for api in SAFE_APIS:
            prev_thresholds[api] = HIGH_THRESHOLD
        if pre_window_baseline <= 0:
            pre_window_baseline = max(current_total, 1.0)
        gate_closed = False
        mode = MODE_NORMAL
        shock_left = 0
        for k in mode_counters:
            mode_counters[k] = 0
        print(f"[heuc] t={elapsed:.0f}s entering window, warm-start baseline={pre_window_baseline:.1f}")

    # Build per-API affected signals.
    signals: Dict[str, ApiSignal] = {}
    for api in AFFECTED_APIS:
        baseline_api = pre_window_per_api.get(api, 0.0)
        signals[api] = build_api_signal(
            api=api,
            metric=metric,
            rps_map=rps_map,
            fail_stats=fail_stats,
            baseline_rps=baseline_api,
            target_latency_ms=TARGET_LATENCY_MS,
        )

    affected_rps = sum(s["rps"] for s in signals.values())
    affected_fail = sum(s["fail"] for s in signals.values())
    affected_reject = sum(s["reject"] for s in signals.values())
    affected_timeout = sum(s["timeout_est"] for s in signals.values())
    affected_l95_max = max((s["l95"] for s in signals.values()), default=0.0)
    timeout_share = affected_timeout / max(affected_fail, 1e-6)
    fail_ratio = affected_fail / max(affected_rps, 1e-6)
    latency_excess = max(0.0, affected_l95_max / max(TARGET_LATENCY_MS, 1.0) - 1.0)
    latency_score = min(latency_excess / 2.0, 1.0)
    throughput_drop = 0.0
    if pre_window_baseline > 0:
        throughput_drop = clamp(1.0 - current_total / pre_window_baseline, 0.0, 1.0)
    severity = clamp(
        SEV_W_FAIL * fail_ratio + SEV_W_LAT * latency_score + SEV_W_TIMEOUT * timeout_share,
        0.0,
        1.0,
    )

    if HEUC_ENABLE:
        new_mode, reason = next_mode(
            current_mode=mode,
            severity=severity,
            timeout_share=timeout_share,
            l95_max=affected_l95_max,
            counters=mode_counters,
            conf=MODE_CONF,
        )
    else:
        new_mode, reason = MODE_NORMAL, ""
    if new_mode != mode:
        old_mode = mode
        mode = new_mode
        for k in mode_counters:
            mode_counters[k] = 0
        if mode == MODE_EMERGENCY:
            shock_left = SHOCK_CYCLES
            recovery_hold_left = 0
        elif mode == MODE_RECOVERY and old_mode == MODE_EMERGENCY:
            recovery_hold_left = RECOVERY_HOLD_CYCLES
        elif old_mode == MODE_EMERGENCY:
            shock_left = 0
        elif mode != MODE_RECOVERY:
            recovery_hold_left = 0
        print(f"[heuc] t={elapsed:.0f}s mode {old_mode} -> {mode} ({reason})")

    # Budget from baseline capacity.
    budget_base = pre_window_baseline if pre_window_baseline > 0 else max(current_total, 1.0)
    k_value = clamp(1.0 - BUDGET_A * severity - BUDGET_B * timeout_share, K_MIN, 1.0)
    budget = budget_base * k_value

    floor_ratio = FLOOR_BY_MODE.get(mode, FLOOR_BY_MODE[MODE_NORMAL])
    slew_rate = SLEW_BY_MODE.get(mode, SLEW_BY_MODE[MODE_NORMAL])

    priority_set: Set[str] = set(PRIORITY_APIS)
    non_priority_set: Set[str] = set(a for a in AFFECTED_APIS if a not in priority_set)
    priority_floor_mult = PRIORITY_FLOOR_MULT_BY_MODE.get(mode, 1.0)

    floors: Dict[str, float] = {}
    for api in AFFECTED_APIS:
        floor_baseline = pre_window_per_api.get(api, 0.0)
        base_floor = max(MIN_THRESHOLD, floor_ratio * floor_baseline)
        if api in priority_set:
            base_floor = max(base_floor, base_floor * priority_floor_mult)
        floors[api] = base_floor
    floor_sum = sum(floors.values())
    residual_budget = max(budget - floor_sum, 0.0)

    # Stage-B urgency weighting (timeout-aware).
    timeout_norm = normalize_positive({api: s["timeout_est"] for api, s in signals.items()})
    lat_norm = normalize_positive({api: s["lat_excess"] for api, s in signals.items()})
    drop_norm = normalize_positive({api: s["drop"] for api, s in signals.items()})
    priority_urg_mult = PRIORITY_URG_MULT_BY_MODE.get(mode, 1.0)
    urgency: Dict[str, float] = {}
    for api in AFFECTED_APIS:
        base_u = (
            URG_ALPHA_TIMEOUT * timeout_norm.get(api, 0.0)
            + URG_BETA_LAT * lat_norm.get(api, 0.0)
            + URG_GAMMA_DROP * drop_norm.get(api, 0.0)
        )
        if base_u <= 0.0:
            base_u = 1.0
        weighted = WEIGHTS.get(api, 1.0) * base_u
        if api in priority_set:
            weighted *= priority_urg_mult
        urgency[api] = weighted
    urgency_sum = sum(urgency.values())

    # Stage-A: reserve part of residual for priority APIs.
    priority_reserve_ratio = PRIORITY_RESERVE_BY_MODE.get(mode, 0.0) if priority_set else 0.0
    priority_reserve = residual_budget * clamp(priority_reserve_ratio, 0.0, 1.0)
    general_budget = max(residual_budget - priority_reserve, 0.0)
    shares: Dict[str, float] = {api: 0.0 for api in AFFECTED_APIS}

    if general_budget > 0 and urgency_sum > 0:
        for api in AFFECTED_APIS:
            shares[api] += general_budget * urgency[api] / urgency_sum

    if priority_reserve > 0 and priority_set:
        priority_urg_sum = sum(urgency.get(api, 0.0) for api in priority_set)
        if priority_urg_sum > 0:
            for api in priority_set:
                shares[api] += priority_reserve * urgency.get(api, 0.0) / priority_urg_sum
        else:
            even_share = priority_reserve / max(len(priority_set), 1)
            for api in priority_set:
                shares[api] += even_share

    # Stage-B guardrail: cap non-priority residual share in harsh modes.
    non_priority_cap_ratio = NON_PRIORITY_MAX_SHARE_BY_MODE.get(mode, 1.0)
    if mode == MODE_RECOVERY and recovery_hold_left > 0:
        non_priority_cap_ratio = min(non_priority_cap_ratio, RECOVERY_HOLD_NON_PRIORITY_CAP)
    if non_priority_set and residual_budget > 0:
        non_priority_cap_total = residual_budget * clamp(non_priority_cap_ratio, 0.0, 1.0)
        non_priority_alloc = sum(shares.get(api, 0.0) for api in non_priority_set)
        if non_priority_alloc > non_priority_cap_total:
            scale = non_priority_cap_total / non_priority_alloc if non_priority_alloc > 0 else 0.0
            reclaimed = 0.0
            for api in non_priority_set:
                prev_alloc = shares.get(api, 0.0)
                shares[api] = prev_alloc * scale
                reclaimed += prev_alloc - shares[api]
            if reclaimed > 0 and priority_set:
                priority_urg_sum = sum(urgency.get(api, 0.0) for api in priority_set)
                if priority_urg_sum > 0:
                    for api in priority_set:
                        shares[api] += reclaimed * urgency.get(api, 0.0) / priority_urg_sum
                else:
                    even_share = reclaimed / max(len(priority_set), 1)
                    for api in priority_set:
                        shares[api] += even_share

    new_thresholds: ThresholdMap = {}
    for api in AFFECTED_APIS:
        target = floors[api] + shares.get(api, 0.0)

        # Emergency shock: aggressively suppress queue growth for first few rounds.
        if mode == MODE_EMERGENCY and shock_left > 0:
            target = max(floors[api], target * SHOCK_FACTOR)

        # Avoid over-release in NORMAL/RECOVERY.
        curr_r = signals[api]["rps"]
        if mode in (MODE_NORMAL, MODE_RECOVERY) and curr_r > 0:
            target = min(target, max(floors[api], curr_r * 1.2))

        lower = max(MIN_THRESHOLD, prev_thresholds[api] * (1.0 - slew_rate))
        upper = max(MIN_THRESHOLD, prev_thresholds[api] * (1.0 + slew_rate))
        new_thresholds[api] = max(floors[api], clamp(target, lower, upper))

    for api in SAFE_APIS:
        curr = api_rps(api, metric, rps_map)
        new_thresholds[api] = max(curr * 1.1, HIGH_THRESHOLD)

    apply_thresholds(new_thresholds)
    prev_thresholds = dict(new_thresholds)
    if mode == MODE_EMERGENCY and shock_left > 0:
        shock_left -= 1
    if mode == MODE_RECOVERY and recovery_hold_left > 0:
        recovery_hold_left -= 1
    was_in_window = True

    thr_str = " ".join(f"{api}={new_thresholds[api]:.1f}" for api in ALL_APIS if api in new_thresholds)
    print(
        f"[heuc] t={elapsed:.0f}s mode={mode} severity={severity:.3f} "
        f"fail={fail_ratio:.3f} reject={affected_reject/max(affected_rps,1e-6):.3f} "
        f"timeout_share={timeout_share:.3f} l95={affected_l95_max:.1f}ms drop={throughput_drop:.2f} "
        f"k={k_value:.2f} budget={budget:.1f}/{budget_base:.1f} floor_sum={floor_sum:.1f} "
        f"residual={residual_budget:.1f} prio_reserve={priority_reserve:.1f} nonprio_cap={non_priority_cap_ratio:.2f} "
        f"slew={slew_rate:.2f} shock_left={shock_left} rec_hold={recovery_hold_left} | {thr_str}"
    )
