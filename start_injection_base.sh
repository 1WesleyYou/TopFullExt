#!/usr/bin/env bash
set -euo pipefail

# Start baseline load for Figure 15 scenario on loadgen node.

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
PROJECT_NAME="${PROJECT_NAME:-TopFullExt}"
MASTER_IP_VALUE="${MASTER_IP:-}"

if [[ -z "${MASTER_IP_VALUE}" ]]; then
  if [[ -n "${SSH_USER:-}" ]]; then
    MASTER_TARGET="${SSH_USER}@${MASTER_NODE:-node0}"
  else
    MASTER_TARGET="${MASTER_NODE:-node0}"
  fi
  MASTER_IP_VALUE="$(ssh "${MASTER_TARGET}" "hostname -I | awk '{print \$1}'" | tr -d '[:space:]')"
fi

LOAD_RATE="${LOAD_RATE:-100}"

ssh "${LOADGEN_TARGET}" bash -s -- "${PROJECT_NAME}" "${MASTER_IP_VALUE}" "${LOAD_RATE}" <<'REMOTE'
set -euo pipefail
project_name="${1:-TopFullExt}"
master_ip="${2:?master_ip required}"
export LOAD_RATE="${3:-100}"
loadgen_dir="${HOME}/${project_name}/TopFull_loadgen"

cd "${loadgen_dir}"
ulimit -n 65535 || true
export PATH="${HOME}/.local/bin:${PATH}"
if ! command -v locust >/dev/null 2>&1; then
  python3 -m pip install --user "locust==2.8.6"
fi
# Rewrite target frontend/proxy endpoint before every run.
sed -i -E "s|--host=http://[0-9.]+:30440|--host=http://${master_ip}:30440|g" run_fig15_online_boutique_base.sh
sed -i -E "s|http://[0-9.]+:8090|http://${master_ip}:8090|g" locust_online_boutique.py
bash ./run_fig15_online_boutique_base.sh
tmux ls 2>/dev/null | egrep 'session4|session5|session6' || true
pgrep -af locust >/dev/null || { echo "locust did not start"; exit 1; }
REMOTE

