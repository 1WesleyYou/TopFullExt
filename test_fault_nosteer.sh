#!/usr/bin/env bash
set -euo pipefail

# No-mitigation baseline: inject fault, observe, no REJECT at all.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_RATE="${BASE_RATE:-25}"
NET_LOSS_PCT="${NET_LOSS_PCT:-30}"
POD_COUNT="${POD_COUNT:-2}"
BASE_SETTLE="${BASE_SETTLE:-90}"
FAULT_SEC="${FAULT_SEC:-180}"
TAIL_SEC="${TAIL_SEC:-90}"
PHASE_LOG="${SCRIPT_DIR}/phase_markers_nosteer.env"

ts() { printf "[%s]" "$(date +'%H:%M:%S')"; }
append_phase() {
  local key="$1" iso epoch
  iso="$(date -Iseconds)"; epoch="$(date -u +%s)"
  printf "%s_ISO=%s\n%s_EPOCH=%s\n" "${key}" "${iso}" "${key}" "${epoch}" >> "${PHASE_LOG}"
}
cleanup() {
  echo "$(ts) Cleanup..."
  bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear 2>/dev/null || true
  make -C "${SCRIPT_DIR}" stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "$(ts) === No-Steer Baseline (POD_COUNT=${POD_COUNT}, ${NET_LOSS_PCT}% loss) ==="
: > "${PHASE_LOG}"
cat >> "${PHASE_LOG}" <<EOF
BASE_RATE=${BASE_RATE}
NET_LOSS_PCT=${NET_LOSS_PCT}
POD_COUNT=${POD_COUNT}
BASE_SETTLE=${BASE_SETTLE}
FAULT_SEC=${FAULT_SEC}
TAIL_SEC=${TAIL_SEC}
EOF

bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear 2>/dev/null || true
append_phase "BASE_LOAD_START"
make -C "${SCRIPT_DIR}" inject-base "RATE=${BASE_RATE}"
echo "$(ts) warmup ${BASE_SETTLE}s..."
sleep "${BASE_SETTLE}"

append_phase "NET_DELAY_START"
echo "$(ts) inject ${NET_LOSS_PCT}% loss on ${POD_COUNT} pods"
export NET_LOSS_PCT NET_DIRECTION=egress NET_TARGET_POD_COUNT="${POD_COUNT}"
bash "${SCRIPT_DIR}/net_delay_k8s.sh" set
echo "$(ts) observing ${FAULT_SEC}s (NO MITIGATION)..."
sleep "${FAULT_SEC}"

append_phase "NET_DELAY_END"
echo "$(ts) clearing netem"
bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear
append_phase "TAIL_START"
sleep "${TAIL_SEC}"
append_phase "EXPERIMENT_END"
echo "$(ts) Done."
