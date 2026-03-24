#!/usr/bin/env bash
set -euo pipefail

# Start/restart TopFull RL stack on master node:
# - proxy
# - RL controller
# - metric collector

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

# Ensure cAdvisor is ready before starting RL; otherwise CPU metrics may stay stale.
echo "[rl] Ensuring cAdvisor is ready on ${MASTER_TARGET}..."
bash "${SCRIPT_DIR}/ensure_cadvisor.sh"

# Sync runtime files to avoid stale remote scripts.
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/deploy_rl.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/metric_collector.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/overload_detection.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/resource_collector.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/skeleton_simulator.py"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/global_config.json"
push_runtime_file "${MASTER_REPO_DIR}" "TopFull_master/online_boutique_scripts/src/proxy/proxy_online_boutique.go"

ssh "${MASTER_TARGET}" bash -s -- \
  "${MASTER_REPO_DIR}" \
  "${NET_DELAY_MS:-0}" \
  "${NET_JITTER_MS:-0}" \
  "${NET_INJECT_AT_SEC:-0}" \
  "${NET_RELEASE_AT_SEC:-0}" \
  <<'REMOTE'
set -euo pipefail
repo_dir="${1:?repo_dir required}"
net_delay_ms="${2:-0}"
net_jitter_ms="${3:-0}"
net_inject_at_sec="${4:-0}"
net_release_at_sec="${5:-0}"
src_dir="${repo_dir}/TopFull_master/online_boutique_scripts/src"

cd "${src_dir}"
mkdir -p "${src_dir}/proxy/rate_config" "${src_dir}/logs"

tmux kill-session -t topfull-proxy 2>/dev/null || true
tmux kill-session -t topfull-controller 2>/dev/null || true
tmux kill-session -t topfull-metrics 2>/dev/null || true

: > /tmp/topfull-proxy.log
: > /tmp/topfull-controller.log
: > /tmp/topfull-metrics.log

tmux new-session -d -s topfull-proxy "ulimit -n 65535 || true; cd '${src_dir}/proxy' && NET_DELAY_MS=${net_delay_ms} NET_JITTER_MS=${net_jitter_ms} NET_INJECT_AT_SEC=${net_inject_at_sec} NET_RELEASE_AT_SEC=${net_release_at_sec} go run proxy_online_boutique.go > /tmp/topfull-proxy.log 2>&1"
tmux new-session -d -s topfull-controller "cd '${src_dir}' && PYTHONUNBUFFERED=1 FORCED_GATE=1 python3 deploy_rl.py > /tmp/topfull-controller.log 2>&1"
tmux new-session -d -s topfull-metrics "cd '${src_dir}' && python3 metric_collector.py > /tmp/topfull-metrics.log 2>&1"

tmux ls
pgrep -af 'proxy_online_boutique|deploy_rl.py|metric_collector.py' || true
REMOTE

