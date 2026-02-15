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
echo "__JOIN_CMD__=${join_cmd} --cri-socket unix://var/run/cri-dockerd.sock"
REMOTE
}

run_setup_worker() {
  local target="$1"
  local repo_dir="$2"
  local join_cmd="$3"

  ssh "${target}" bash -s -- "${repo_dir}" "${join_cmd}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:?repo_dir required}"
join_cmd="${2:?join_cmd required}"
cd "${repo_dir}"
./setup.sh worker "${join_cmd}"
REMOTE
}

main() {
  local master_target worker_target loadgen_target
  local master_repo_dir worker_repo_dir loadgen_repo_dir
  local master_log join_cmd

  master_target="$(target_host "${MASTER_HOST}")"
  worker_target="$(target_host "${WORKER_HOST}")"
  loadgen_target="$(target_host "${LOADGEN_HOST}")"
  master_log="$(mktemp)"
  trap 'rm -f "${master_log}"' EXIT

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
}

main "$@"
exit 0
#!/usr/bin/env bash
set -euo pipefail

# Coordinate cluster setup from one machine:
# 1) Distribute local repo + .env to node0/node1/node2
# 2) SSH to master node, run setup.sh master
# 3) Fetch join command from master
# 4) SSH to worker node, run setup.sh worker "<join_cmd>"
#
# Usage:
#   ./coordinate_setup.sh
#
# Optional environment overrides:
#   MASTER_NODE / WORKER_NODE / LOADGEN_NODE   (default: node0 / node1 / node2)
#   SSH_USER                    (default: current user)
#   PROJECT_NAME                (default: TopFullExt)
#   REMOTE_REPO_DIR             (default: $HOME/$PROJECT_NAME on remote)
#   SKIP_LOADGEN_SYNC=1         (skip repo/.env sync to loadgen node)

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
SKIP_LOADGEN_SYNC="${SKIP_LOADGEN_SYNC:-0}"

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
  local cmd
  cmd="$(printf 'set -euo pipefail; project_name=%q; remote_repo_dir=%q; if [[ -n "$remote_repo_dir" ]]; then printf "%%s" "$remote_repo_dir"; else printf "%%s" "$HOME/$project_name"; fi' "${PROJECT_NAME}" "${REMOTE_REPO_DIR}")"
  ssh "${target}" bash -c "${cmd}"
}

sync_repo_to_remote() {
  local target="$1"
  local repo_dir="$2"
  local cmd

  log "Syncing local repository to ${target}:${repo_dir}"
  cmd="$(printf 'set -euo pipefail; repo_dir=%q; mkdir -p "$repo_dir"; tar -xf - -C "$repo_dir"' "${repo_dir}")"

  tar -C "${SCRIPT_DIR}" \
    --exclude=".git" \
    --exclude=".cursor" \
    --exclude=".venv" \
    --exclude="__pycache__" \
    --exclude="*.pyc" \
    -cf - . | ssh "${target}" bash -c "${cmd}"
}

push_env_to_remote() {
  local target="$1"
  local repo_dir="$2"
  local cmd

  if [[ ! -f "${ENV_FILE}" ]]; then
    log "No local .env found, skip env distribution to ${target}"
    return
  fi

  log "Pushing .env to ${target}:${repo_dir}/.env"
  cmd="$(printf 'set -euo pipefail; repo_dir=%q; mkdir -p "$repo_dir"; cat > "$repo_dir/.env"' "${repo_dir}")"
  ssh "${target}" bash -c "${cmd}" < "${ENV_FILE}"
}

ensure_remote_setup_scripts() {
  local target="$1"
  local repo_dir="$2"
  local cmd
  cmd="$(printf 'set -euo pipefail; repo_dir=%q; chmod +x "$repo_dir/setup.sh" "$repo_dir/setup_master.sh" "$repo_dir/setup_worker.sh" || true' "${repo_dir}")"
  ssh "${target}" bash -c "${cmd}"
}

run_remote_setup_master() {
  local target="$1"
  local repo_dir="$2"
  local log_file="$3"

  ssh "${target}" bash -s -- "${repo_dir}" <<'REMOTE' | tee "${log_file}"
set -euo pipefail
repo_dir="${1:-}"
if [[ -z "${repo_dir}" ]]; then
  echo "remote repo dir is empty"
  exit 1
fi

cd "${repo_dir}"
chmod +x setup.sh setup_master.sh setup_worker.sh || true
./setup.sh master

join_cmd="$(sudo kubeadm token create --print-join-command)"
echo "__JOIN_CMD__=${join_cmd} --cri-socket unix://var/run/cri-dockerd.sock"
REMOTE
}

run_remote_setup_worker() {
  local target="$1"
  local repo_dir="$2"
  local join_cmd="$3"

  ssh "${target}" bash -s -- "${repo_dir}" "${join_cmd}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:-}"
join_cmd="${2:-}"
if [[ -z "${repo_dir}" ]]; then
  echo "remote repo dir is empty"
  exit 1
fi
if [[ -z "${join_cmd}" ]]; then
  echo "join command is empty"
  exit 1
fi

cd "${repo_dir}"
chmod +x setup.sh setup_master.sh setup_worker.sh || true
./setup.sh worker "${join_cmd}"
REMOTE
}

main() {
  local master_target worker_target loadgen_target
  local master_repo_dir worker_repo_dir loadgen_repo_dir
  local master_log join_cmd

  master_target="$(target_host "${MASTER_HOST}")"
  worker_target="$(target_host "${WORKER_HOST}")"
  loadgen_target="$(target_host "${LOADGEN_HOST}")"
  master_log="$(mktemp)"

  trap 'rm -f "${master_log}"' EXIT

  log "Coordinating setup via SSH"
  log "Master: ${master_target}, Worker: ${worker_target}, Loadgen: ${loadgen_target}"

  master_repo_dir="$(resolve_remote_repo_dir "${master_target}")"
  worker_repo_dir="$(resolve_remote_repo_dir "${worker_target}")"
  loadgen_repo_dir="$(resolve_remote_repo_dir "${loadgen_target}")"

  log "Step 0/2: distribute local repo + .env"
  sync_repo_to_remote "${master_target}" "${master_repo_dir}"
  push_env_to_remote "${master_target}" "${master_repo_dir}"
  ensure_remote_setup_scripts "${master_target}" "${master_repo_dir}"

  sync_repo_to_remote "${worker_target}" "${worker_repo_dir}"
  push_env_to_remote "${worker_target}" "${worker_repo_dir}"
  ensure_remote_setup_scripts "${worker_target}" "${worker_repo_dir}"

  if [[ "${SKIP_LOADGEN_SYNC}" != "1" ]]; then
    sync_repo_to_remote "${loadgen_target}" "${loadgen_repo_dir}"
    push_env_to_remote "${loadgen_target}" "${loadgen_repo_dir}"
    ensure_remote_setup_scripts "${loadgen_target}" "${loadgen_repo_dir}"
  else
    log "SKIP_LOADGEN_SYNC=1, skip loadgen distribution"
  fi

  log "Step 1/2: setup master on ${master_target}"
  run_remote_setup_master "${master_target}" "${master_repo_dir}" "${master_log}"

  join_cmd="$(sed -n 's/^__JOIN_CMD__=//p' "${master_log}" | tail -n 1)"
  if [[ -z "${join_cmd}" ]]; then
    echo "Failed to capture join command from master setup output."
    echo "Please check the logs above."
    exit 1
  fi

  log "Step 2/2: setup worker on ${worker_target}"
  run_remote_setup_worker "${worker_target}" "${worker_repo_dir}" "${join_cmd}"

  log "Done. Cluster bootstrap flow completed."
}

main "$@"
exit 0
#!/usr/bin/env bash
set -euo pipefail

# Coordinate cluster setup from one machine:
# 1) Distribute local repo + .env to node0/node1/node2
# 2) SSH to master node, run setup.sh master
# 3) Fetch join command from master
# 4) SSH to worker node, run setup.sh worker "<join_cmd>"
#
# Usage:
#   ./coordinate_setup.sh
#
# Optional environment overrides:
#   MASTER_NODE / WORKER_NODE / LOADGEN_NODE   (default: node0 / node1 / node2)
#   SSH_USER                    (default: current user)
#   PROJECT_NAME                (default: TopFullExt)
#   REMOTE_REPO_DIR             (default: $HOME/$PROJECT_NAME on remote)
#   SKIP_LOADGEN_SYNC=1         (skip repo/.env sync to loadgen node)

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
SKIP_LOADGEN_SYNC="${SKIP_LOADGEN_SYNC:-0}"

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
  repo_dir="${remote_repo_dir}"
else
  repo_dir="${HOME}/${project_name}"
fi

printf "%s" "${repo_dir}"
REMOTE
}

sync_repo_to_remote() {
  local target="$1"
  local repo_dir="$2"

  log "Syncing local repository to ${target}:${repo_dir}"
  tar -C "${SCRIPT_DIR}" \
    --exclude=".git" \
    --exclude=".cursor" \
    --exclude=".venv" \
    --exclude="__pycache__" \
    --exclude="*.pyc" \
    -cf - . | ssh "${target}" bash -s -- "${repo_dir}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:-}"
if [[ -z "${repo_dir}" ]]; then
  echo "remote repo dir is empty"
  exit 1
fi
mkdir -p "${repo_dir}"
tar -xf - -C "${repo_dir}"
REMOTE
}

push_env_to_remote() {
  local target="$1"
  local repo_dir="$2"

  if [[ ! -f "${ENV_FILE}" ]]; then
    log "No local .env found, skip env distribution to ${target}"
    return
  fi

  log "Pushing .env to ${target}:${repo_dir}/.env"
  ssh "${target}" bash -lc "$(printf 'mkdir -p %q && cat > %q' "${repo_dir}" "${repo_dir}/.env")" < "${ENV_FILE}"
}

ensure_remote_setup_scripts() {
  local target="$1"
  local repo_dir="$2"
  ssh "${target}" bash -lc "$(printf 'chmod +x %q %q %q || true' "${repo_dir}/setup.sh" "${repo_dir}/setup_master.sh" "${repo_dir}/setup_worker.sh")"
}

run_remote_setup_master() {
  local target="$1"
  local repo_dir="$2"
  local log_file="$3"

  ssh "${target}" bash -s -- "${repo_dir}" <<'REMOTE' | tee "${log_file}"
set -euo pipefail
repo_dir="${1:-}"
if [[ -z "${repo_dir}" ]]; then
  echo "remote repo dir is empty"
  exit 1
fi

cd "${repo_dir}"
chmod +x setup.sh setup_master.sh setup_worker.sh || true
./setup.sh master

join_cmd="$(sudo kubeadm token create --print-join-command)"
echo "__JOIN_CMD__=${join_cmd} --cri-socket unix://var/run/cri-dockerd.sock"
REMOTE
}

run_remote_setup_worker() {
  local target="$1"
  local repo_dir="$2"
  local join_cmd="$3"

  ssh "${target}" bash -s -- "${repo_dir}" "${join_cmd}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:-}"
join_cmd="${2:-}"
if [[ -z "${repo_dir}" ]]; then
  echo "remote repo dir is empty"
  exit 1
fi
if [[ -z "${join_cmd}" ]]; then
  echo "join command is empty"
  exit 1
fi

cd "${repo_dir}"
chmod +x setup.sh setup_master.sh setup_worker.sh || true
./setup.sh worker "${join_cmd}"
REMOTE
}

main() {
  local master_target worker_target loadgen_target
  local master_repo_dir worker_repo_dir loadgen_repo_dir
  local master_log join_cmd

  master_target="$(target_host "${MASTER_HOST}")"
  worker_target="$(target_host "${WORKER_HOST}")"
  loadgen_target="$(target_host "${LOADGEN_HOST}")"
  master_log="$(mktemp)"

  trap 'rm -f "${master_log}"' EXIT

  log "Coordinating setup via SSH"
  log "Master: ${master_target}, Worker: ${worker_target}, Loadgen: ${loadgen_target}"

  master_repo_dir="$(resolve_remote_repo_dir "${master_target}")"
  worker_repo_dir="$(resolve_remote_repo_dir "${worker_target}")"
  loadgen_repo_dir="$(resolve_remote_repo_dir "${loadgen_target}")"

  log "Step 0/2: distribute local repo + .env"
  sync_repo_to_remote "${master_target}" "${master_repo_dir}"
  push_env_to_remote "${master_target}" "${master_repo_dir}"
  ensure_remote_setup_scripts "${master_target}" "${master_repo_dir}"

  sync_repo_to_remote "${worker_target}" "${worker_repo_dir}"
  push_env_to_remote "${worker_target}" "${worker_repo_dir}"
  ensure_remote_setup_scripts "${worker_target}" "${worker_repo_dir}"

  if [[ "${SKIP_LOADGEN_SYNC}" != "1" ]]; then
    sync_repo_to_remote "${loadgen_target}" "${loadgen_repo_dir}"
    push_env_to_remote "${loadgen_target}" "${loadgen_repo_dir}"
    ensure_remote_setup_scripts "${loadgen_target}" "${loadgen_repo_dir}"
  else
    log "SKIP_LOADGEN_SYNC=1, skip loadgen distribution"
  fi

  log "Step 1/2: setup master on ${master_target}"
  run_remote_setup_master "${master_target}" "${master_repo_dir}" "${master_log}"

  join_cmd="$(sed -n 's/^__JOIN_CMD__=//p' "${master_log}" | tail -n 1)"
  if [[ -z "${join_cmd}" ]]; then
    echo "Failed to capture join command from master setup output."
    echo "Please check the logs above."
    exit 1
  fi

  log "Step 2/2: setup worker on ${worker_target}"
  run_remote_setup_worker "${worker_target}" "${worker_repo_dir}" "${join_cmd}"

  log "Done. Cluster bootstrap flow completed."
}

main "$@"
exit 0
#!/usr/bin/env bash
set -euo pipefail

# Coordinate cluster setup from one machine:
# 1) Distribute local repo + .env to node0/node1/node2
# 2) SSH to master node, run setup.sh master
# 3) Fetch join command from master
# 4) SSH to worker node, run setup.sh worker "<join_cmd>"
#
# Usage:
#   ./coordinate_setup.sh
#
# Optional environment overrides:
#   MASTER_NODE / WORKER_NODE / LOADGEN_NODE   (default: node0 / node1 / node2)
#   SSH_USER                    (default: current user)
#   PROJECT_NAME                (default: TopFullExt)
#   REMOTE_REPO_DIR             (default: $HOME/$PROJECT_NAME on remote)
#   SKIP_LOADGEN_SYNC=1         (skip repo/.env sync to loadgen node)

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
SKIP_LOADGEN_SYNC="${SKIP_LOADGEN_SYNC:-0}"

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
project_name="$1"
remote_repo_dir="$2"

if [[ -n "${remote_repo_dir}" ]]; then
  repo_dir="${remote_repo_dir}"
else
  repo_dir="${HOME}/${project_name}"
fi

printf "%s" "${repo_dir}"
REMOTE
}

sync_repo_to_remote() {
  local target="$1"
  local repo_dir="$2"

  log "Syncing local repository to ${target}:${repo_dir}"
  tar -C "${SCRIPT_DIR}" \
    --exclude=".git" \
    --exclude=".cursor" \
    --exclude=".venv" \
    --exclude="__pycache__" \
    --exclude="*.pyc" \
    -cf - . | ssh "${target}" bash -s -- "${repo_dir}" <<'REMOTE'
set -euo pipefail
repo_dir="$1"
mkdir -p "${repo_dir}"
tar -xf - -C "${repo_dir}"
REMOTE
}

push_env_to_remote() {
  local target="$1"
  local repo_dir="$2"

  if [[ ! -f "${ENV_FILE}" ]]; then
    log "No local .env found, skip env distribution to ${target}"
    return
  fi

  log "Pushing .env to ${target}:${repo_dir}/.env"
  ssh "${target}" bash -lc "$(printf 'mkdir -p %q && cat > %q' "${repo_dir}" "${repo_dir}/.env")" < "${ENV_FILE}"
}

ensure_remote_setup_scripts() {
  local target="$1"
  local repo_dir="$2"
  ssh "${target}" bash -lc "$(printf 'chmod +x %q %q %q || true' "${repo_dir}/setup.sh" "${repo_dir}/setup_master.sh" "${repo_dir}/setup_worker.sh")"
}

run_remote_setup_master() {
  local target="$1"
  local repo_dir="$2"
  local log_file="$3"

  ssh "${target}" bash -s -- "${repo_dir}" <<'REMOTE' | tee "${log_file}"
set -euo pipefail
repo_dir="$1"

cd "${repo_dir}"
chmod +x setup.sh setup_master.sh setup_worker.sh || true
./setup.sh master

join_cmd="$(sudo kubeadm token create --print-join-command)"
echo "__JOIN_CMD__=${join_cmd} --cri-socket unix://var/run/cri-dockerd.sock"
REMOTE
}

run_remote_setup_worker() {
  local target="$1"
  local repo_dir="$2"
  local join_cmd="$3"

  ssh "${target}" bash -s -- "${repo_dir}" "${join_cmd}" <<'REMOTE'
set -euo pipefail
repo_dir="$1"
join_cmd="$2"

cd "${repo_dir}"
chmod +x setup.sh setup_master.sh setup_worker.sh || true
./setup.sh worker "${join_cmd}"
REMOTE
}

main() {
  local master_target worker_target loadgen_target
  local master_repo_dir worker_repo_dir loadgen_repo_dir
  local master_log join_cmd

  master_target="$(target_host "${MASTER_HOST}")"
  worker_target="$(target_host "${WORKER_HOST}")"
  loadgen_target="$(target_host "${LOADGEN_HOST}")"
  master_log="$(mktemp)"

  trap 'rm -f "${master_log}"' EXIT

  log "Coordinating setup via SSH"
  log "Master: ${master_target}, Worker: ${worker_target}, Loadgen: ${loadgen_target}"

  master_repo_dir="$(resolve_remote_repo_dir "${master_target}")"
  worker_repo_dir="$(resolve_remote_repo_dir "${worker_target}")"
  loadgen_repo_dir="$(resolve_remote_repo_dir "${loadgen_target}")"

  log "Step 0/2: distribute local repo + .env"
  sync_repo_to_remote "${master_target}" "${master_repo_dir}"
  push_env_to_remote "${master_target}" "${master_repo_dir}"
  ensure_remote_setup_scripts "${master_target}" "${master_repo_dir}"

  sync_repo_to_remote "${worker_target}" "${worker_repo_dir}"
  push_env_to_remote "${worker_target}" "${worker_repo_dir}"
  ensure_remote_setup_scripts "${worker_target}" "${worker_repo_dir}"

  if [[ "${SKIP_LOADGEN_SYNC}" != "1" ]]; then
    sync_repo_to_remote "${loadgen_target}" "${loadgen_repo_dir}"
    push_env_to_remote "${loadgen_target}" "${loadgen_repo_dir}"
    ensure_remote_setup_scripts "${loadgen_target}" "${loadgen_repo_dir}"
  else
    log "SKIP_LOADGEN_SYNC=1, skip loadgen distribution"
  fi

  log "Step 1/2: setup master on ${master_target}"
  run_remote_setup_master "${master_target}" "${master_repo_dir}" "${master_log}"

  join_cmd="$(sed -n 's/^__JOIN_CMD__=//p' "${master_log}" | tail -n 1)"
  if [[ -z "${join_cmd}" ]]; then
    echo "Failed to capture join command from master setup output."
    echo "Please check the logs above."
    exit 1
  fi

  log "Step 2/2: setup worker on ${worker_target}"
  run_remote_setup_worker "${worker_target}" "${worker_repo_dir}" "${join_cmd}"

  log "Done. Cluster bootstrap flow completed."
}

main "$@"
exit 0
#!/usr/bin/env bash
set -euo pipefail

# Coordinate cluster setup from one machine:
# 1) Distribute local repo + .env to node0/node1/node2
# 2) SSH to master node, run setup.sh master
# 3) Fetch join command from master
# 4) SSH to worker node, run setup.sh worker "<join_cmd>"
#
# Usage:
#   ./coordinate_setup.sh
#
# Optional environment overrides:
#   MASTER_NODE / WORKER_NODE / LOADGEN_NODE   (default: node0 / node1 / node2)
#   SSH_USER                    (default: current user)
#   PROJECT_NAME                (default: TopFullExt)
#   REMOTE_REPO_DIR             (default: $HOME/$PROJECT_NAME on remote)
#   SKIP_LOADGEN_SYNC=1         (skip repo/.env sync to loadgen node)

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
SKIP_LOADGEN_SYNC="${SKIP_LOADGEN_SYNC:-0}"

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
project_name="$1"
remote_repo_dir="$2"

if [[ -n "${remote_repo_dir}" ]]; then
  repo_dir="${remote_repo_dir}"
else
  repo_dir="${HOME}/${project_name}"
fi

printf "%s" "${repo_dir}"
REMOTE
}

sync_repo_to_remote() {
  local target="$1"
  local repo_dir="$2"

  log "Syncing local repository to ${target}:${repo_dir}"
  tar -C "${SCRIPT_DIR}" \
    --exclude=".git" \
    --exclude=".cursor" \
    --exclude=".venv" \
    --exclude="__pycache__" \
    --exclude="*.pyc" \
    -cf - . | ssh "${target}" bash -s -- "${repo_dir}" <<'REMOTE'
set -euo pipefail
repo_dir="$1"
mkdir -p "${repo_dir}"
tar -xf - -C "${repo_dir}"
REMOTE
}

push_env_to_remote() {
  local target="$1"
  local repo_dir="$2"

  if [[ ! -f "${ENV_FILE}" ]]; then
    log "No local .env found, skip env distribution to ${target}"
    return
  fi

  log "Pushing .env to ${target}:${repo_dir}/.env"
  ssh "${target}" bash -lc "$(printf 'mkdir -p %q && cat > %q' "${repo_dir}" "${repo_dir}/.env")" < "${ENV_FILE}"
}

ensure_remote_setup_scripts() {
  local target="$1"
  local repo_dir="$2"
  ssh "${target}" bash -lc "$(printf 'chmod +x %q %q %q || true' "${repo_dir}/setup.sh" "${repo_dir}/setup_master.sh" "${repo_dir}/setup_worker.sh")"
}

run_remote_setup_master() {
  local target="$1"
  local repo_dir="$2"
  local log_file="$3"

  ssh "${target}" bash -s -- "${repo_dir}" <<'REMOTE' | tee "${log_file}"
set -euo pipefail
repo_dir="$1"

cd "${repo_dir}"
chmod +x setup.sh setup_master.sh setup_worker.sh || true
./setup.sh master

join_cmd="$(sudo kubeadm token create --print-join-command)"
echo "__JOIN_CMD__=${join_cmd} --cri-socket unix://var/run/cri-dockerd.sock"
REMOTE
}

run_remote_setup_worker() {
  local target="$1"
  local repo_dir="$2"
  local join_cmd="$3"

  ssh "${target}" bash -s -- "${repo_dir}" "${join_cmd}" <<'REMOTE'
set -euo pipefail
repo_dir="$1"
join_cmd="$2"

cd "${repo_dir}"
chmod +x setup.sh setup_master.sh setup_worker.sh || true
./setup.sh worker "${join_cmd}"
REMOTE
}

main() {
  local master_target worker_target loadgen_target
  local master_repo_dir worker_repo_dir loadgen_repo_dir
  local master_log join_cmd

  master_target="$(target_host "${MASTER_HOST}")"
  worker_target="$(target_host "${WORKER_HOST}")"
  loadgen_target="$(target_host "${LOADGEN_HOST}")"
  master_log="$(mktemp)"

  trap 'rm -f "${master_log}"' EXIT

  log "Coordinating setup via SSH"
  log "Master: ${master_target}, Worker: ${worker_target}, Loadgen: ${loadgen_target}"

  master_repo_dir="$(resolve_remote_repo_dir "${master_target}")"
  worker_repo_dir="$(resolve_remote_repo_dir "${worker_target}")"
  loadgen_repo_dir="$(resolve_remote_repo_dir "${loadgen_target}")"

  log "Step 0/2: distribute local repo + .env"
  sync_repo_to_remote "${master_target}" "${master_repo_dir}"
  push_env_to_remote "${master_target}" "${master_repo_dir}"
  ensure_remote_setup_scripts "${master_target}" "${master_repo_dir}"

  sync_repo_to_remote "${worker_target}" "${worker_repo_dir}"
  push_env_to_remote "${worker_target}" "${worker_repo_dir}"
  ensure_remote_setup_scripts "${worker_target}" "${worker_repo_dir}"

  if [[ "${SKIP_LOADGEN_SYNC}" != "1" ]]; then
    sync_repo_to_remote "${loadgen_target}" "${loadgen_repo_dir}"
    push_env_to_remote "${loadgen_target}" "${loadgen_repo_dir}"
    ensure_remote_setup_scripts "${loadgen_target}" "${loadgen_repo_dir}"
  else
    log "SKIP_LOADGEN_SYNC=1, skip loadgen distribution"
  fi

  log "Step 1/2: setup master on ${master_target}"
  run_remote_setup_master "${master_target}" "${master_repo_dir}" "${master_log}"

  join_cmd="$(sed -n 's/^__JOIN_CMD__=//p' "${master_log}" | tail -n 1)"
  if [[ -z "${join_cmd}" ]]; then
    echo "Failed to capture join command from master setup output."
    echo "Please check the logs above."
    exit 1
  fi

  log "Step 2/2: setup worker on ${worker_target}"
  run_remote_setup_worker "${worker_target}" "${worker_repo_dir}" "${join_cmd}"

  log "Done. Cluster bootstrap flow completed."
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

# Coordinate cluster setup from one machine:
# 1) SSH to master node, clone/update repo, run setup.sh master
# 2) Fetch join command from master
# 3) SSH to worker node, clone/update repo, run setup.sh worker "<join_cmd>"
#
# Usage:
#   ./coordinate_setup.sh
#
# Optional environment overrides:
#   MASTER_NODE / WORKER_NODE   (default: node0 / node1)
#   SSH_USER                    (default: current user)
#   REPO_URL                    (default: git origin url of this repo)
#   BRANCH                      (default: current local branch)
#   PROJECT_NAME                (default: TopFullExt)
#   REMOTE_REPO_DIR             (default: $HOME/$PROJECT_NAME on remote)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

MASTER_HOST="${MASTER_NODE:-node0}"
WORKER_HOST="${WORKER_NODE:-node1}"
SSH_USER="${SSH_USER:-}"
PROJECT_NAME="${PROJECT_NAME:-TopFullExt}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-}"

REPO_URL="${REPO_URL:-$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true)}"
BRANCH="${BRANCH:-$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"

if [[ -z "${REPO_URL}" ]]; then
  echo "Cannot detect git origin URL. Please set REPO_URL and retry."
  exit 1
fi

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

run_remote_setup_master() {
  local target="$1"
  local log_file="$2"

  ssh "${target}" bash -s -- "${REPO_URL}" "${BRANCH}" "${PROJECT_NAME}" "${REMOTE_REPO_DIR}" <<'REMOTE' | tee "${log_file}"
set -euo pipefail
repo_url="$1"
branch="$2"
project_name="$3"
remote_repo_dir="$4"

if [[ -n "${remote_repo_dir}" ]]; then
  repo_dir="${remote_repo_dir}"
else
  repo_dir="${HOME}/${project_name}"
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git not found on $(hostname), installing..."
  sudo apt-get update
  sudo apt-get install -y git
fi

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
  echo "WARNING: branch '${branch}' not found on origin, keeping current checked-out branch."
fi

chmod +x setup.sh setup_master.sh setup_worker.sh
./setup.sh master

join_cmd="$(sudo kubeadm token create --print-join-command)"
echo "__JOIN_CMD__=${join_cmd} --cri-socket unix://var/run/cri-dockerd.sock"
REMOTE
}

run_remote_setup_worker() {
  local target="$1"
  local join_cmd="$2"

  ssh "${target}" bash -s -- "${REPO_URL}" "${BRANCH}" "${PROJECT_NAME}" "${REMOTE_REPO_DIR}" "${join_cmd}" <<'REMOTE'
set -euo pipefail
repo_url="$1"
branch="$2"
project_name="$3"
remote_repo_dir="$4"
join_cmd="$5"

if [[ -n "${remote_repo_dir}" ]]; then
  repo_dir="${remote_repo_dir}"
else
  repo_dir="${HOME}/${project_name}"
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git not found on $(hostname), installing..."
  sudo apt-get update
  sudo apt-get install -y git
fi

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
  echo "WARNING: branch '${branch}' not found on origin, keeping current checked-out branch."
fi

chmod +x setup.sh setup_master.sh setup_worker.sh
./setup.sh worker "${join_cmd}"
REMOTE
}

main() {
  local master_target worker_target master_log join_cmd
  master_target="$(target_host "${MASTER_HOST}")"
  worker_target="$(target_host "${WORKER_HOST}")"
  master_log="$(mktemp)"

  trap 'rm -f "${master_log}"' EXIT

  log "Coordinating setup via SSH"
  log "Master: ${master_target}, Worker: ${worker_target}"
  log "Repo: ${REPO_URL}, Branch: ${BRANCH}"

  log "Step 1/2: setup master on ${master_target}"
  run_remote_setup_master "${master_target}" "${master_log}"

  join_cmd="$(sed -n 's/^__JOIN_CMD__=//p' "${master_log}" | tail -n 1)"
  if [[ -z "${join_cmd}" ]]; then
    echo "Failed to capture join command from master setup output."
    echo "Please check the logs above."
    exit 1
  fi

  log "Step 2/2: setup worker on ${worker_target}"
  run_remote_setup_worker "${worker_target}" "${join_cmd}"

  log "Done. Cluster bootstrap flow completed."
}

main "$@"
