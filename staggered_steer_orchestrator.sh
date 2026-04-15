#!/usr/bin/env bash
# Staggered force-steer: REJECT one pod at a time to observe incremental recovery.
#
# Usage:
#   POD_IPS="ip1 ip2 ip3" BASE_S=106 FIRST_DELAY_S=10 STEP_S=25 FAULT_DUR=120 \
#     bash staggered_steer_orchestrator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

NODES="${NODES:-node0 node1 node2}"
PORT="${STEERING_SERVICE_PORT:-3550}"
BASE_S="${BASE_S:-106}"            # measured: ~106s from script start to actual fault
FIRST_DELAY_S="${FIRST_DELAY_S:-10}"
STEP_S="${STEP_S:-25}"
FAULT_DUR="${FAULT_DUR:-120}"

: "${POD_IPS:?set POD_IPS='ip1 ip2 ip3'}"

LOG="${SCRIPT_DIR}/staggered_steer_events.log"
log() { echo "[$(date -Iseconds)] $*" | tee -a "${LOG}"; }

apply_reject() {
  local ip="$1"
  for n in ${NODES}; do
    ssh -o BatchMode=yes "${n}" "sudo iptables -I FORWARD -d '${ip}' -p tcp --dport '${PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true; sudo conntrack -D -d '${ip}' 2>/dev/null | wc -l" >/dev/null 2>&1 || true
  done
}

remove_reject() {
  local ip="$1"
  for n in ${NODES}; do
    ssh -o BatchMode=yes "${n}" "sudo iptables -D FORWARD -d '${ip}' -p tcp --dport '${PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true; sudo conntrack -D -d '${ip}' 2>/dev/null | wc -l" >/dev/null 2>&1 || true
  done
}

# Convert POD_IPS to array
read -ra IPS <<< "${POD_IPS}"
N=${#IPS[@]}
log "Staggered steering: ${N} pods, first REJECT at t=${BASE_S}+${FIRST_DELAY_S}=$((BASE_S+FIRST_DELAY_S))s, step=${STEP_S}s"
log "Pod IPs: ${POD_IPS}"

# Wait until first REJECT time
sleep $((BASE_S + FIRST_DELAY_S))

# Apply one at a time with step delay
for i in "${!IPS[@]}"; do
  apply_reject "${IPS[$i]}"
  log "APPLY $((i+1))/${N}: ${IPS[$i]}"
  if [[ $((i+1)) -lt ${N} ]]; then
    sleep "${STEP_S}"
  fi
done

# All applied. How much time left in fault window?
# Total elapsed from script start: BASE_S + FIRST_DELAY_S + (N-1)*STEP_S
ELAPSED=$((BASE_S + FIRST_DELAY_S + (N-1)*STEP_S))
FAULT_END_AT=$((BASE_S + FAULT_DUR))
HOLD_UNTIL_RELEASE=$((FAULT_END_AT - ELAPSED - 5))  # release 5s before fault ends
if [[ ${HOLD_UNTIL_RELEASE} -gt 0 ]]; then
  log "All ${N} REJECTed; holding for ${HOLD_UNTIL_RELEASE}s"
  sleep "${HOLD_UNTIL_RELEASE}"
fi

# Remove all REJECTs at once
for ip in "${IPS[@]}"; do
  remove_reject "${ip}"
  log "REMOVE ${ip}"
done
log "Released"
