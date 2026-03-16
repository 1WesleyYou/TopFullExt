#!/usr/bin/env bash
set -euo pipefail

# Start surge load for Figure 15 scenario on loadgen node.

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

LOADGEN_TARGET="$(target_host "${LOADGEN_NODE:-node2}")"
PROJECT_NAME="${PROJECT_NAME:-TopFullExt}"
MASTER_IP_VALUE="${MASTER_IP:-}"
INJECT_DURATION="${1:-${INJECT_DURATION:-15m}}"

if [[ ! "${INJECT_DURATION}" =~ ^[0-9]+[smhd]$ ]]; then
  echo "Invalid duration: ${INJECT_DURATION}. Expected format like 30m, 2h, 45s."
  exit 1
fi

if [[ -z "${MASTER_IP_VALUE}" ]]; then
  if [[ -n "${SSH_USER:-}" ]]; then
    MASTER_TARGET="${SSH_USER}@${MASTER_NODE:-node0}"
  else
    MASTER_TARGET="${MASTER_NODE:-node0}"
  fi
  MASTER_IP_VALUE="$(ssh "${MASTER_TARGET}" "hostname -I | awk '{print \$1}'" | tr -d '[:space:]')"
fi

ssh "${LOADGEN_TARGET}" bash -s -- "${PROJECT_NAME}" "${MASTER_IP_VALUE}" "${INJECT_DURATION}" <<'REMOTE'
set -euo pipefail
project_name="${1:-TopFullExt}"
master_ip="${2:?master_ip required}"
duration="${3:-15m}"
loadgen_dir="${HOME}/${project_name}/TopFull_loadgen"

cd "${loadgen_dir}"
ulimit -n 65535 || true
export PATH="${HOME}/.local/bin:${PATH}"
if ! command -v locust >/dev/null 2>&1; then
  python3 -m pip install --user "locust==2.8.6"
fi
# Rewrite target frontend/proxy endpoint before every run.
sed -i -E "s|--host=http://[0-9.]+:30440|--host=http://${master_ip}:30440|g" run_fig15_online_boutique.sh
sed -i -E "s|http://[0-9.]+:8090|http://${master_ip}:8090|g" locust_online_boutique.py
sed -i -E "s|-t [0-9]+[smhd]|-t ${duration}|g" run_fig15_online_boutique.sh
bash ./run_fig15_online_boutique.sh
tmux ls 2>/dev/null | egrep 'session1|session2|session3' || true
pgrep -af locust >/dev/null || { echo "locust did not start"; exit 1; }
REMOTE

