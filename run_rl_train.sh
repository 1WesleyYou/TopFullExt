#!/usr/bin/env bash
set -euo pipefail

# Start/restart TopFull online RL training stack on master node:
# - proxy
# - metric collector
# - transfer learning trainer
#
# NOTE:
# - This script does NOT start load injection.
# - Run load separately (e.g., make inject-surge) for training traffic.

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

MASTER_TARGET="$(target_host "${MASTER_NODE:-node0}")"
PROJECT_NAME="${PROJECT_NAME:-TopFullExt}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-}"

resolve_remote_repo_dir() {
  ssh "${MASTER_TARGET}" bash -s -- "${PROJECT_NAME}" "${REMOTE_REPO_DIR}" <<'REMOTE'
set -euo pipefail
project_name="${1:-TopFullExt}"
remote_repo_dir="${2:-}"
if [[ -n "${remote_repo_dir}" ]]; then
  printf "%s" "${remote_repo_dir}"
else
  printf "%s" "${HOME}/${project_name}"
fi
REMOTE
}

push_runtime_file() {
  local remote_repo="$1"
  local rel="$2"
  local src="${SCRIPT_DIR}/${rel}"
  local dst="${remote_repo}/${rel}"
  ssh "${MASTER_TARGET}" "mkdir -p \"$(dirname "${dst}")\""
  scp "${src}" "${MASTER_TARGET}:${dst}"
}

MASTER_REPO_DIR="$(resolve_remote_repo_dir)"

echo "[train] Ensuring cAdvisor is ready on ${MASTER_TARGET}..."
bash "${SCRIPT_DIR}/ensure_cadvisor.sh"

# Sync runtime files to avoid stale scripts on master.
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/transfer_learning.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/metric_collector.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/overload_detection.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/resource_collector.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/skeleton_simulator.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/global_config.json"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/proxy/proxy_online_boutique.go"

ssh "${MASTER_TARGET}" bash -s -- "${MASTER_REPO_DIR}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:?repo_dir required}"
src_dir="${repo_dir}/TopFull_master/online_boutique_scripts/src"

cd "${src_dir}"
mkdir -p "${src_dir}/proxy/rate_config" "${src_dir}/logs"
mkdir -p "${src_dir}/models_transfer/v1tmp1/rllib_checkpoint"

# Keep loadgen sessions untouched; only reset master-side runtime.
tmux kill-session -t topfull-proxy 2>/dev/null || true
tmux kill-session -t topfull-controller 2>/dev/null || true
tmux kill-session -t topfull-metrics 2>/dev/null || true
tmux kill-session -t topfull-train 2>/dev/null || true

: > /tmp/topfull-proxy.log
: > /tmp/topfull-metrics.log
: > /tmp/topfull-train.log

tmux new-session -d -s topfull-proxy "ulimit -n 65535 || true; cd '${src_dir}/proxy' && go run proxy_online_boutique.go > /tmp/topfull-proxy.log 2>&1"
tmux new-session -d -s topfull-metrics "cd '${src_dir}' && python3 metric_collector.py > /tmp/topfull-metrics.log 2>&1"
tmux new-session -d -s topfull-train "cd '${src_dir}' && PYTHONUNBUFFERED=1 python3 transfer_learning.py > /tmp/topfull-train.log 2>&1"

tmux ls
pgrep -af 'proxy_online_boutique|metric_collector.py|transfer_learning.py' || true
REMOTE

echo "[train] Started online RL training on master."
echo "[train] Training log: ssh ${MASTER_TARGET} 'tail -f /tmp/topfull-train.log'"
echo "[train] Trigger workload separately, e.g.: make inject-surge"
