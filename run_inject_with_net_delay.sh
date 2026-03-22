#!/usr/bin/env bash
set -euo pipefail

# Wrapper:
# 1) clear existing delay rules
# 2) start load injection (default: make inject)
# 3) timed network delay set/clear window
#
# Defaults:
#   INJECT_TARGET=inject
#   NET_INJECT_AT_SEC=70
#   NET_RELEASE_AT_SEC=200
#
# Usage:
#   ./run_inject_with_net_delay.sh
#   INJECT_TARGET=inject-base NET_INJECT_AT_SEC=60 NET_RELEASE_AT_SEC=180 ./run_inject_with_net_delay.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

INJECT_TARGET="${INJECT_TARGET:-inject}"
INJECT_AT_SEC="${NET_INJECT_AT_SEC:-70}"
RELEASE_AT_SEC="${NET_RELEASE_AT_SEC:-200}"

log() {
  printf "[%s] %s\n" "$(date +'%F %T')" "$*"
}

cleanup_on_exit() {
  log "Wrapper exit cleanup: clear network delay rules"
  bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear || true
}

main() {
  trap cleanup_on_exit EXIT INT TERM

  log "Step 1/3: clear any existing network delay rules"
  bash "${SCRIPT_DIR}/net_delay_k8s.sh" clear || true

  log "Step 2/3: start load injection via make ${INJECT_TARGET}"
  make -C "${SCRIPT_DIR}" "${INJECT_TARGET}"

  log "Step 3/3: timed network delay window (inject=${INJECT_AT_SEC}s, release=${RELEASE_AT_SEC}s)"
  NET_INJECT_AT_SEC="${INJECT_AT_SEC}" \
  NET_RELEASE_AT_SEC="${RELEASE_AT_SEC}" \
  bash "${SCRIPT_DIR}/net_delay_k8s.sh" run

  log "Timed window completed"
}

main "$@"
