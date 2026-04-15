#!/usr/bin/env bash
# Force-steer orchestrator: apply iptables REJECT to KNOWN target pods at fault+13s.
# Assumes fault_start = netdelay_script_start + 90s (BASE window).
#
# Usage (must be run from experiment/TopFullExt):
#   NET_TARGET_PODS="podA podB" POD_IPS="ip1 ip2" DELAY_S=13 FAULT_DUR=120 \
#     bash force_steer_orchestrator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

NODES="${NODES:-node0 node1 node2}"
PORT="${STEERING_SERVICE_PORT:-3550}"
DELAY_S="${DELAY_S:-13}"          # how long AFTER fault_start to activate mitigation
FAULT_DUR="${FAULT_DUR:-120}"
BASE_S="${BASE_S:-90}"             # seconds between script start and fault start

: "${POD_IPS:?must set POD_IPS='ip1 ip2 ...'}"

LOG="${SCRIPT_DIR}/force_steer_events.log"
log() { echo "[$(date -Iseconds)] $*" | tee -a "${LOG}"; }

# Wait BASE phase + DELAY_S to land right after fault starts.
SLEEP_UNTIL_APPLY=$(( BASE_S + DELAY_S ))
log "Will apply REJECT after ${SLEEP_UNTIL_APPLY}s (BASE=${BASE_S} + DELAY=${DELAY_S})"
log "Pod IPs: ${POD_IPS}"
log "Nodes:   ${NODES}"

sleep "${SLEEP_UNTIL_APPLY}"

# APPLY REJECT + flush conntrack on all nodes for all pod IPs
APPLY_TS=$(date +%s)
for ip in ${POD_IPS}; do
  for node in ${NODES}; do
    ssh -o BatchMode=yes "${node}" "sudo iptables -I FORWARD -d '${ip}' -p tcp --dport '${PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true; sudo conntrack -D -d '${ip}' 2>/dev/null | wc -l" >/dev/null 2>&1 || true
  done
  log "APPLIED REJECT for ${ip} on all nodes"
done
log "Mitigation active @ ${APPLY_TS}"

# Sleep until fault ends (fault_start + fault_dur)
# Already used SLEEP_UNTIL_APPLY seconds since start. Remaining to fault_end:
REMAIN=$(( BASE_S + FAULT_DUR - SLEEP_UNTIL_APPLY - 5 ))
# use -5 to remove mitigation 5s before fault_end so TAIL is clean
sleep "${REMAIN}"

# REMOVE REJECT rules
for ip in ${POD_IPS}; do
  for node in ${NODES}; do
    ssh -o BatchMode=yes "${node}" "sudo iptables -D FORWARD -d '${ip}' -p tcp --dport '${PORT}' -j REJECT --reject-with tcp-reset 2>/dev/null || true; sudo conntrack -D -d '${ip}' 2>/dev/null | wc -l" >/dev/null 2>&1 || true
  done
  log "REMOVED REJECT for ${ip}"
done
log "Mitigation released"
