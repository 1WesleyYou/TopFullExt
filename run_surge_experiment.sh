#!/usr/bin/env bash
set -euo pipefail

# Base → Surge → Base tail → Stop
#
# Timeline (defaults):
#   0:00  base load starts
#   1:00  surge overlay begins (base continues)
#   1:40  surge ends automatically (-t flag)
#   3:40  experiment complete, all load stopped
#
# Usage:
#   ./run_surge_experiment.sh
#   BASE_SETTLE=90 SURGE_SEC=60 TAIL_SEC=180 ./run_surge_experiment.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

BASE_SETTLE="${BASE_SETTLE:-90}"
SURGE_SEC="${SURGE_SEC:-120}"
TAIL_SEC="${TAIL_SEC:-120}"
TOTAL=$(( BASE_SETTLE + SURGE_SEC + TAIL_SEC ))

ts() { printf "[%s]" "$(date +'%H:%M:%S')"; }

cleanup() {
  echo "$(ts) Stopping all load injection..."
  make -C "${SCRIPT_DIR}" stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "$(ts) === Surge Experiment ==="
echo "$(ts) Plan: base ${BASE_SETTLE}s → surge ${SURGE_SEC}s → tail ${TAIL_SEC}s (total ${TOTAL}s)"
echo ""

echo "$(ts) Phase 1/3: starting base load, settling for ${BASE_SETTLE}s"
make -C "${SCRIPT_DIR}" inject-base
sleep "${BASE_SETTLE}"

echo ""
echo "$(ts) Phase 2/3: injecting surge for ${SURGE_SEC}s (base continues)"
INJECT_DURATION="${SURGE_SEC}s" "${SCRIPT_DIR}/start_injection_surge.sh"
sleep "${SURGE_SEC}"

echo ""
echo "$(ts) Phase 3/3: post-surge tail ${TAIL_SEC}s (base still running)"
sleep "${TAIL_SEC}"

echo ""
echo "$(ts) Experiment complete. Cleanup will stop all processes."
