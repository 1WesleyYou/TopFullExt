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

LOADGEN_TARGET="$(target_host "${LOADGEN_NODE:-node2}")"
PROJECT_NAME="${PROJECT_NAME:-TopFullExt}"

ssh "${LOADGEN_TARGET}" bash -s -- "${PROJECT_NAME}" <<'REMOTE'
set -euo pipefail
project_name="${1:-TopFullExt}"
loadgen_dir="${HOME}/${project_name}/TopFull_loadgen"

cd "${loadgen_dir}"
bash ./run_fig15_online_boutique_base.sh
tmux ls 2>/dev/null | egrep 'session4|session5|session6' || true
REMOTE

