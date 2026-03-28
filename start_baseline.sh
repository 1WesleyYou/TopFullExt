#!/usr/bin/env bash
set -euo pipefail

# Start baseline (no TopFull control): loadgen only, traffic goes directly to frontend.
# Do not start the controller stack (no proxy rate limiting).
# Optionally start metric_collector on master to record the same CSV for comparison.
#
# Usage:
#   ./start_baseline.sh
#   make baseline
#
# Before running: ensure app is deployed (e.g. after coordinate_setup or deploy_stage2_node0).
# Then: make stop && make baseline

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

target_host() {
  local host="$1"
  if [[ -n "${SSH_USER:-}" ]]; then
    printf "%s@%s" "${SSH_USER}" "${host}"
  else
    printf "%s" "${host}"
  fi
}

LOADGEN_TARGET="$(target_host "${LOADGEN_NODE:-node3}")"
MASTER_TARGET="$(target_host "${MASTER_NODE:-node0}")"
PROJECT_NAME="${PROJECT_NAME:-TopFullExt}"
MASTER_IP_VALUE="${MASTER_IP:-}"

if [[ -z "${MASTER_IP_VALUE}" ]]; then
  MASTER_IP_VALUE="$(ssh "${MASTER_TARGET}" "hostname -I | awk '{print \$1}'" | tr -d '[:space:]')"
fi

echo "Baseline (no control): starting loadgen on ${LOADGEN_TARGET} with TOPFULL_BASELINE=1 (no proxy)."
ssh "${LOADGEN_TARGET}" bash -s -- "${PROJECT_NAME}" "${MASTER_IP_VALUE}" <<'REMOTE'
set -euo pipefail
project_name="${1:-TopFullExt}"
master_ip="${2:?master_ip required}"
loadgen_dir="${HOME}/${project_name}/TopFull_loadgen"

cd "${loadgen_dir}"
ulimit -n 65535 || true
export PATH="${HOME}/.local/bin:${PATH}"
if ! command -v locust >/dev/null 2>&1; then
  python3 -m pip install --user "locust==2.8.6"
fi
sed -i -E "s|--host=http://[0-9.]+:30440|--host=http://${master_ip}:30440|g" online_boutique_create.sh online_boutique_create2.sh
sed -i -E "s|http://[0-9.]+:8090|http://${master_ip}:8090|g" locust_online_boutique.py
# Run create script with TOPFULL_BASELINE=1 so every locust process skips proxy (direct to frontend).
sed 's/locust -f/TOPFULL_BASELINE=1 locust -f/g' online_boutique_create.sh | bash
tmux ls 2>/dev/null | egrep 'session1|session2|session3' || true
pgrep -af locust >/dev/null || { echo "locust did not start"; exit 1; }
echo "Baseline loadgen running (traffic to frontend:30440, no proxy)."
REMOTE

echo "Optional: to record metrics CSV on master, run:"
echo "  ssh ${MASTER_TARGET} 'cd ~/${PROJECT_NAME}/TopFull_master/online_boutique_scripts/src && tmux new-session -d -s topfull-metrics python3 metric_collector.py'"
