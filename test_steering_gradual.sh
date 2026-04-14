#!/usr/bin/env bash
set -euo pipefail

# Gradual hardcoded REJECT: bypass detection, but REJECT pods one-at-a-time
# with spacing to avoid gRPC reconnection storms.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_RATE="${BASE_RATE:-25}"
NET_LOSS_PCT="${NET_LOSS_PCT:-30}"
POD_COUNT="${POD_COUNT:-3}"
BASE_SETTLE="${BASE_SETTLE:-90}"
FAULT_SEC="${FAULT_SEC:-180}"   # longer fault window to fit gradual REJECT
STEER_DELAY="${STEER_DELAY:-30}"
REJECT_SPACING="${REJECT_SPACING:-20}"   # seconds between individual REJECTs
TAIL_SEC="${TAIL_SEC:-90}"
SERVICE_PORT="${SERVICE_PORT:-3550}"
NODES="${NODES:-node0 node1 node2}"
PHASE_LOG="${SCRIPT_DIR}/phase_markers_gradual.env"

FAULTY_POD_IPS=""

ts() { printf "[%s]" "$(date +'%H:%M:%S')"; }

append_phase() {
  local key="$1" iso epoch
  iso="$(date -Iseconds)"; epoch="$(date -u +%s)"
  printf "%s_ISO=%s\n%s_EPOCH=%s\n" "${key}" "${iso}" "${key}" "${epoch}" >> "${PHASE_LOG}"
}

cleanup() {
  echo "$(ts) Cleanup: clearing netem + removing REJECT rules..."
  bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear 2>/dev/null || true
  if [[ -n "${FAULTY_POD_IPS}" ]]; then
    for ip in ${FAULTY_POD_IPS}; do
      for node in ${NODES}; do
        ssh "${node}" "sudo iptables -D FORWARD -d '${ip}' -p tcp --dport '${SERVICE_PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true" || true
      done
    done
  fi
  make -C "${SCRIPT_DIR}" stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "$(ts) === Gradual Hardcoded REJECT Test ==="
echo "$(ts) BASE_RATE=${BASE_RATE}%  NET_LOSS_PCT=${NET_LOSS_PCT}%  POD_COUNT=${POD_COUNT}"
echo "$(ts) REJECT_SPACING=${REJECT_SPACING}s (one pod rejected every ${REJECT_SPACING}s)"
echo ""

: > "${PHASE_LOG}"
cat >> "${PHASE_LOG}" <<EOF
BASE_RATE=${BASE_RATE}
NET_LOSS_PCT=${NET_LOSS_PCT}
POD_COUNT=${POD_COUNT}
BASE_SETTLE=${BASE_SETTLE}
FAULT_SEC=${FAULT_SEC}
STEER_DELAY=${STEER_DELAY}
REJECT_SPACING=${REJECT_SPACING}
TAIL_SEC=${TAIL_SEC}
EOF

echo "$(ts) Step 0: pre-clear netem"
bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear 2>/dev/null || true

echo "$(ts) Step 1: start base load RATE=${BASE_RATE}%"
append_phase "BASE_LOAD_START"
make -C "${SCRIPT_DIR}" inject-base "RATE=${BASE_RATE}"

echo "$(ts) Step 2: waiting ${BASE_SETTLE}s for warmup..."
sleep "${BASE_SETTLE}"

append_phase "NET_DELAY_START"
echo "$(ts) Step 3: injecting ${NET_LOSS_PCT}% loss on ${POD_COUNT} pods"
export NET_LOSS_PCT NET_DIRECTION=egress NET_TARGET_POD_COUNT="${POD_COUNT}"
bash "${SCRIPT_DIR}/net_delay_k8s.sh" set

FAULTY_POD_IPS="$(ssh node0 "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -l app=productcatalogservice --no-headers -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{\"\n\"}{end}'" | head -${POD_COUNT} | awk '{print $2}' | tr '\n' ' ')"
echo "$(ts) Faulty pod IPs: ${FAULTY_POD_IPS}"

echo "$(ts) Step 4: fault active, waiting ${STEER_DELAY}s..."
sleep "${STEER_DELAY}"

# Gradual REJECT: one pod at a time, spaced
append_phase "STEER_START"
i=0
total_reject_time=0
for ip in ${FAULTY_POD_IPS}; do
  i=$((i+1))
  append_phase "REJECT_${i}"
  echo "$(ts) Step 5.${i}: REJECT ${ip}"
  for node in ${NODES}; do
    ssh "${node}" "sudo iptables -I FORWARD -d '${ip}' -p tcp --dport '${SERVICE_PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true" || true
    ssh "${node}" "sudo conntrack -D -p tcp -d '${ip}' --dport '${SERVICE_PORT}' 2>/dev/null || true" || true
  done
  if [[ "${i}" -lt "${POD_COUNT}" ]]; then
    echo "$(ts)   waiting ${REJECT_SPACING}s before next REJECT..."
    sleep "${REJECT_SPACING}"
    total_reject_time=$((total_reject_time + REJECT_SPACING))
  fi
done

# Observe remaining fault duration
local_remaining=$(( FAULT_SEC - STEER_DELAY - total_reject_time ))
if [[ "${local_remaining}" -lt 0 ]]; then local_remaining=0; fi
echo "$(ts) Step 6: all REJECTs applied, observing for ${local_remaining}s..."
sleep "${local_remaining}"

append_phase "NET_DELAY_END"
echo "$(ts) Step 7: clearing netem + removing REJECT rules"
bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear
for ip in ${FAULTY_POD_IPS}; do
  for node in ${NODES}; do
    ssh "${node}" "sudo iptables -D FORWARD -d '${ip}' -p tcp --dport '${SERVICE_PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true" || true
  done
done
FAULTY_POD_IPS=""

append_phase "TAIL_START"
echo "$(ts) Step 8: post-fault tail ${TAIL_SEC}s"
sleep "${TAIL_SEC}"

append_phase "EXPERIMENT_END"
echo "$(ts) Done."
