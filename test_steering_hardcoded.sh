#!/usr/bin/env bash
set -euo pipefail

# Hardcoded steering test: bypass detection, directly REJECT the 3 known-faulty pods.
# This isolates the mitigation layer from the detection layer to answer:
#   "Does FORWARD REJECT actually recover goodput during valley?"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_RATE="${BASE_RATE:-25}"
NET_LOSS_PCT="${NET_LOSS_PCT:-30}"
POD_COUNT="${POD_COUNT:-3}"
BASE_SETTLE="${BASE_SETTLE:-90}"
FAULT_SEC="${FAULT_SEC:-140}"
STEER_DELAY="${STEER_DELAY:-30}"
TAIL_SEC="${TAIL_SEC:-90}"
SERVICE_PORT="${SERVICE_PORT:-3550}"
NODES="${NODES:-node0 node1 node2}"
PHASE_LOG="${SCRIPT_DIR}/phase_markers_hardcoded.env"

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

echo "$(ts) === Hardcoded Steering Test ==="
echo "$(ts) BASE_RATE=${BASE_RATE}%  NET_LOSS_PCT=${NET_LOSS_PCT}%  POD_COUNT=${POD_COUNT}"
echo "$(ts) Timeline: base ${BASE_SETTLE}s -> fault ${FAULT_SEC}s (REJECT at +${STEER_DELAY}s) -> tail ${TAIL_SEC}s"
echo ""

: > "${PHASE_LOG}"
echo "BASE_RATE=${BASE_RATE}" >> "${PHASE_LOG}"
echo "NET_LOSS_PCT=${NET_LOSS_PCT}" >> "${PHASE_LOG}"
echo "POD_COUNT=${POD_COUNT}" >> "${PHASE_LOG}"
echo "BASE_SETTLE=${BASE_SETTLE}" >> "${PHASE_LOG}"
echo "FAULT_SEC=${FAULT_SEC}" >> "${PHASE_LOG}"
echo "STEER_DELAY=${STEER_DELAY}" >> "${PHASE_LOG}"
echo "TAIL_SEC=${TAIL_SEC}" >> "${PHASE_LOG}"

# Step 0: pre-clear
echo "$(ts) Step 0: pre-clear netem"
bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear 2>/dev/null || true

# Step 1: start base load
echo "$(ts) Step 1: start base load RATE=${BASE_RATE}%"
append_phase "BASE_LOAD_START"
make -C "${SCRIPT_DIR}" inject-base "RATE=${BASE_RATE}"

# Step 2: wait warmup
echo "$(ts) Step 2: waiting ${BASE_SETTLE}s for warmup..."
sleep "${BASE_SETTLE}"

# Step 3: inject netem + capture exact pod IPs
append_phase "NET_DELAY_START"
echo "$(ts) Step 3: injecting ${NET_LOSS_PCT}% loss on ${POD_COUNT} pods"
export NET_LOSS_PCT NET_TARGET_POD_COUNT="${POD_COUNT}"
bash "${SCRIPT_DIR}/net_delay_k8s.sh" set

# Capture the exact faulty pod IPs (from kubectl, picking first POD_COUNT pods)
FAULTY_POD_IPS="$(ssh node0 "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -l app=productcatalogservice --no-headers -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{\"\n\"}{end}'" | head -${POD_COUNT} | awk '{print $2}' | tr '\n' ' ')"
echo "$(ts) Faulty pod IPs (hardcoded): ${FAULTY_POD_IPS}"

# Step 4: wait STEER_DELAY (let valley develop)
echo "$(ts) Step 4: fault active, waiting ${STEER_DELAY}s for valley to develop..."
sleep "${STEER_DELAY}"

# Step 5: DIRECT REJECT all 3 faulty pods at once
append_phase "STEER_START"
echo "$(ts) Step 5: HARDCODED REJECT on all ${POD_COUNT} faulty pods at once"
for ip in ${FAULTY_POD_IPS}; do
  for node in ${NODES}; do
    ssh "${node}" "sudo iptables -I FORWARD -d '${ip}' -p tcp --dport '${SERVICE_PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true" || true
  done
  # Flush conntrack for this IP
  for node in ${NODES}; do
    ssh "${node}" "sudo conntrack -D -p tcp -d '${ip}' --dport '${SERVICE_PORT}' 2>/dev/null || true" || true
  done
  echo "$(ts)   REJECT applied for ${ip}"
done

# Step 6: observe remaining fault duration
local_remaining=$(( FAULT_SEC - STEER_DELAY ))
echo "$(ts) Step 6: REJECT active, observing for ${local_remaining}s..."
sleep "${local_remaining}"

# Step 7: clear fault + remove REJECT
append_phase "NET_DELAY_END"
echo "$(ts) Step 7: clearing netem + removing REJECT rules"
bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear
for ip in ${FAULTY_POD_IPS}; do
  for node in ${NODES}; do
    ssh "${node}" "sudo iptables -D FORWARD -d '${ip}' -p tcp --dport '${SERVICE_PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true" || true
  done
done
FAULTY_POD_IPS=""

# Step 8: tail
append_phase "TAIL_START"
echo "$(ts) Step 8: post-fault tail ${TAIL_SEC}s"
sleep "${TAIL_SEC}"

append_phase "EXPERIMENT_END"
echo "$(ts) Done."
