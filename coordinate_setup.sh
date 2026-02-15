#!/usr/bin/env bash
set -euo pipefail

# Coordinate cluster setup from one machine:
# 1) Ensure repo exists on node0/node1/node2 via git clone/pull
# 2) Optionally push local .env to all nodes via scp
# 3) Run setup.sh master on node0
# 4) Get join command from node0 and run setup.sh worker on node1
#
# Usage:
#   ./coordinate_setup.sh
#
# Optional env overrides:
#   MASTER_NODE / WORKER_NODE / LOADGEN_NODE   (default: node0 / node1 / node2)
#   SSH_USER                    (default: current user)
#   PROJECT_NAME                (default: TopFullExt)
#   REMOTE_REPO_DIR             (default: $HOME/$PROJECT_NAME on remote)
#   REPO_URL                    (default: local git origin URL)
#   BRANCH                      (default: current local branch)
#   SKIP_LOADGEN_PREP=1         (skip preparing loadgen node)
#   RUN_TOPFULL_DEPLOY=1        (also deploy app + start TopFull stack)
#   CONTROLLER_MODE=mimd|rl|without_cluster  (default: mimd)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

MASTER_HOST="${MASTER_NODE:-node0}"
WORKER_HOST="${WORKER_NODE:-node1}"
LOADGEN_HOST="${LOADGEN_NODE:-node2}"
SSH_USER="${SSH_USER:-}"
PROJECT_NAME="${PROJECT_NAME:-TopFullExt}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-}"
REPO_URL="${REPO_URL:-$(git -C "${SCRIPT_DIR}" remote get-url origin)}"
BRANCH="${BRANCH:-$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD)}"
SKIP_LOADGEN_PREP="${SKIP_LOADGEN_PREP:-0}"
RUN_TOPFULL_DEPLOY="${RUN_TOPFULL_DEPLOY:-0}"
CONTROLLER_MODE="${CONTROLLER_MODE:-mimd}"

log() {
  printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"
}

target_host() {
  local host="$1"
  if [[ -n "${SSH_USER}" ]]; then
    printf "%s@%s" "${SSH_USER}" "${host}"
  else
    printf "%s" "${host}"
  fi
}

resolve_remote_repo_dir() {
  local target="$1"
  ssh "${target}" bash -s -- "${PROJECT_NAME}" "${REMOTE_REPO_DIR}" <<'REMOTE'
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

ensure_repo_on_node() {
  local target="$1"
  local repo_dir="$2"

  log "Preparing repository on ${target}:${repo_dir}"
  ssh "${target}" bash -s -- "${repo_dir}" "${REPO_URL}" "${BRANCH}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:?repo_dir required}"
repo_url="${2:?repo_url required}"
branch="${3:?branch required}"

if ! command -v git >/dev/null 2>&1; then
  echo "git not found on $(hostname), installing..."
  sudo apt-get update
  sudo apt-get install -y git
fi

mkdir -p "$(dirname "${repo_dir}")"

if [[ ! -d "${repo_dir}/.git" ]]; then
  rm -rf "${repo_dir}"
  git clone "${repo_url}" "${repo_dir}"
fi

cd "${repo_dir}"
git fetch origin --prune

if git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
  git checkout "${branch}"
  git pull --ff-only origin "${branch}"
else
  echo "WARNING: branch '${branch}' not found on origin, keeping current branch."
fi

chmod +x setup.sh setup_master.sh setup_worker.sh || true
REMOTE
}

push_env_to_node() {
  local target="$1"
  local repo_dir="$2"

  if [[ ! -f "${ENV_FILE}" ]]; then
    log "No local .env found, skip env push to ${target}"
    return
  fi

  log "Pushing .env to ${target}:${repo_dir}/.env"
  ssh "${target}" "mkdir -p \"${repo_dir}\""
  scp "${ENV_FILE}" "${target}:${repo_dir}/.env"
}

push_setup_scripts_to_node() {
  local target="$1"
  local repo_dir="$2"
  local f

  log "Pushing setup scripts to ${target}:${repo_dir}"
  ssh "${target}" "mkdir -p \"${repo_dir}\""

  for f in setup.sh setup_master.sh setup_worker.sh coordinate_setup.sh; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
      scp "${SCRIPT_DIR}/${f}" "${target}:${repo_dir}/${f}"
    fi
  done

  ssh "${target}" "chmod +x \"${repo_dir}/setup.sh\" \"${repo_dir}/setup_master.sh\" \"${repo_dir}/setup_worker.sh\" || true"
}

push_file_list_to_node() {
  local target="$1"
  local repo_dir="$2"
  shift 2
  local rel src dst_dir

  for rel in "$@"; do
    src="${SCRIPT_DIR}/${rel}"
    if [[ ! -f "${src}" ]]; then
      continue
    fi
    dst_dir="$(dirname "${repo_dir}/${rel}")"
    ssh "${target}" "mkdir -p \"${dst_dir}\""
    scp "${src}" "${target}:${repo_dir}/${rel}"
  done
}

deploy_topfull_master() {
  local target="$1"
  local repo_dir="$2"
  local controller_script

  case "${CONTROLLER_MODE}" in
    rl) controller_script="deploy_rl.py" ;;
    without_cluster) controller_script="deploy_without_cluster.py" ;;
    *) controller_script="deploy_mimd.py" ;;
  esac

  log "Deploying TopFull stack on ${target} (controller: ${controller_script})"
  ssh "${target}" bash -s -- "${repo_dir}" "${controller_script}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:?repo_dir required}"
controller_script="${2:?controller_script required}"
src_dir="${repo_dir}/TopFull_master/online_boutique_scripts/src"

if ! command -v pip3 >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y python3-pip
fi
if ! command -v tmux >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y tmux
fi

cd "${repo_dir}/TopFull_master"
pip3 install -r requirements.txt

kubectl apply -f "${repo_dir}/TopFull_master/online_boutique_scripts/deployments/online_boutique_original_custom.yaml"
kubectl apply -f "${repo_dir}/TopFull_master/online_boutique_scripts/deployments/metric-server-latest.yaml"
python3 "${src_dir}/instance_scaling.py"

tmux kill-session -t topfull-proxy >/dev/null 2>&1 || true
tmux kill-session -t topfull-controller >/dev/null 2>&1 || true
tmux kill-session -t topfull-metrics >/dev/null 2>&1 || true

tmux new-session -d -s topfull-proxy "cd '${src_dir}/proxy' && go run proxy_online_boutique.go"
tmux new-session -d -s topfull-controller "cd '${src_dir}' && python3 ${controller_script}"
tmux new-session -d -s topfull-metrics "cd '${src_dir}' && python3 metric_collector.py"
REMOTE
}

deploy_topfull_loadgen() {
  local target="$1"
  local repo_dir="$2"
  local master_ip="$3"

  log "Deploying loadgen on ${target}"
  ssh "${target}" bash -s -- "${repo_dir}" "${master_ip}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:?repo_dir required}"
master_ip="${2:?master_ip required}"
loadgen_dir="${repo_dir}/TopFull_loadgen"

if ! command -v pip3 >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y python3-pip
fi
if ! command -v tmux >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y tmux
fi

cd "${loadgen_dir}"
pip3 install -r requirements.txt

sed -i -E "s|--host=http://[0-9.]+:30440|--host=http://${master_ip}:30440|g" online_boutique_create.sh online_boutique_create2.sh
sed -i -E "s|http://[0-9.]+:8090|http://${master_ip}:8090|g" locust_online_boutique.py
chmod +x online_boutique_create.sh online_boutique_create2.sh

tmux kill-session -t topfull-loadgen >/dev/null 2>&1 || true
tmux new-session -d -s topfull-loadgen "cd '${loadgen_dir}' && ./online_boutique_create.sh"
REMOTE
}

run_setup_master() {
  local target="$1"
  local repo_dir="$2"
  local log_file="$3"

  ssh "${target}" bash -s -- "${repo_dir}" <<'REMOTE' | tee "${log_file}"
set -euo pipefail
repo_dir="${1:?repo_dir required}"
cd "${repo_dir}"
./setup.sh master
join_cmd="$(sudo kubeadm token create --print-join-command)"
echo "__JOIN_CMD__=${join_cmd}"
REMOTE
}

run_setup_worker() {
  local target="$1"
  local repo_dir="$2"
  local join_cmd="$3"
  local join_cmd_b64

  join_cmd_b64="$(printf "%s" "${join_cmd}" | base64 -w0)"

  ssh "${target}" bash -s -- "${repo_dir}" "${join_cmd_b64}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:?repo_dir required}"
join_cmd_b64="${2:?join_cmd_b64 required}"
join_cmd="$(printf "%s" "${join_cmd_b64}" | base64 -d)"
cd "${repo_dir}"
./setup.sh worker "${join_cmd}"
REMOTE
}

main() {
  local master_target worker_target loadgen_target
  local master_repo_dir worker_repo_dir loadgen_repo_dir
  local master_log join_cmd
  local master_ip_for_deploy

  master_target="$(target_host "${MASTER_HOST}")"
  worker_target="$(target_host "${WORKER_HOST}")"
  loadgen_target="$(target_host "${LOADGEN_HOST}")"
  master_ip_for_deploy="${MASTER_IP:-}"
  master_log="$(mktemp)"
  trap "rm -f '${master_log}'" EXIT

  log "Coordinating setup via SSH"
  log "Master: ${master_target}, Worker: ${worker_target}, Loadgen: ${loadgen_target}"
  log "Repo: ${REPO_URL}, Branch: ${BRANCH}"

  master_repo_dir="$(resolve_remote_repo_dir "${master_target}")"
  worker_repo_dir="$(resolve_remote_repo_dir "${worker_target}")"
  loadgen_repo_dir="$(resolve_remote_repo_dir "${loadgen_target}")"

  log "Step 0/2: prepare repo + .env on nodes"
  ensure_repo_on_node "${master_target}" "${master_repo_dir}"
  push_env_to_node "${master_target}" "${master_repo_dir}"
  push_setup_scripts_to_node "${master_target}" "${master_repo_dir}"

  ensure_repo_on_node "${worker_target}" "${worker_repo_dir}"
  push_env_to_node "${worker_target}" "${worker_repo_dir}"
  push_setup_scripts_to_node "${worker_target}" "${worker_repo_dir}"

  if [[ "${SKIP_LOADGEN_PREP}" != "1" ]]; then
    ensure_repo_on_node "${loadgen_target}" "${loadgen_repo_dir}"
    push_env_to_node "${loadgen_target}" "${loadgen_repo_dir}"
    push_setup_scripts_to_node "${loadgen_target}" "${loadgen_repo_dir}"
  else
    log "SKIP_LOADGEN_PREP=1, skip loadgen preparation"
  fi

  log "Step 1/2: setup master on ${master_target}"
  run_setup_master "${master_target}" "${master_repo_dir}" "${master_log}"

  join_cmd="$(sed -n 's/^__JOIN_CMD__=//p' "${master_log}" | tail -n 1)"
  if [[ -z "${join_cmd}" ]]; then
    echo "Failed to capture join command from master setup output."
    exit 1
  fi

  log "Step 2/2: setup worker on ${worker_target}"
  run_setup_worker "${worker_target}" "${worker_repo_dir}" "${join_cmd}"

  log "Done. Cluster bootstrap flow completed."

  if [[ "${RUN_TOPFULL_DEPLOY}" == "1" ]]; then
    if [[ -z "${master_ip_for_deploy}" ]]; then
      echo "MASTER_IP is empty. Set it in .env for loadgen host/proxy rewrite."
      exit 1
    fi

    log "Step 3/3: push runtime files + deploy TopFull"
    push_file_list_to_node "${master_target}" "${master_repo_dir}" \
      "TopFull_master/online_boutique_scripts/src/global_config.json" \
      "TopFull_master/online_boutique_scripts/src/deploy_rl.py" \
      "TopFull_master/online_boutique_scripts/src/deploy_mimd.py" \
      "TopFull_master/online_boutique_scripts/src/deploy_without_cluster.py" \
      "TopFull_master/online_boutique_scripts/src/metric_collector.py" \
      "TopFull_master/online_boutique_scripts/src/overload_detection.py" \
      "TopFull_master/online_boutique_scripts/src/proxy/proxy_online_boutique.go" \
      "TopFull_master/online_boutique_scripts/src/proxy/proxy_train_ticket.go"

    push_file_list_to_node "${loadgen_target}" "${loadgen_repo_dir}" \
      "TopFull_loadgen/online_boutique_create.sh" \
      "TopFull_loadgen/online_boutique_create2.sh" \
      "TopFull_loadgen/locust_online_boutique.py"

    deploy_topfull_master "${master_target}" "${master_repo_dir}"

    if [[ "${SKIP_LOADGEN_PREP}" != "1" ]]; then
      deploy_topfull_loadgen "${loadgen_target}" "${loadgen_repo_dir}" "${master_ip_for_deploy}"
    fi

    log "TopFull deploy started. Check tmux sessions: topfull-proxy, topfull-controller, topfull-metrics, topfull-loadgen"
  fi
}

main "$@"
