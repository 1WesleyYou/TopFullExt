#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./setup.sh master
#   ./setup.sh worker "<kubeadm join ...>"
#
# Notes:
# - Run on node0 with "master", node1 with "worker".
# - If .env exists next to this script, it will be sourced automatically.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

ROLE="${1:-}"
JOIN_CMD_RAW="${2:-${KUBEADM_JOIN_CMD:-}}"

PROJECT_ROOT="${PROJECT_ROOT:-${HOME}/TopFullExt}"
MASTER_IP="${MASTER_IP:-}"
K8S_VERSION_MINOR="${K8S_VERSION_MINOR:-v1.28}"
K8S_APT_REPO_MINOR="${K8S_APT_REPO_MINOR:-}"
CRI_SOCKET="unix://var/run/cri-dockerd.sock"

log() {
  printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"
}

kubectl_admin() {
  sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"
}

wait_for_apiserver() {
  local retries="${1:-30}"
  local sleep_seconds="${2:-2}"
  local i

  for ((i = 1; i <= retries; i++)); do
    if kubectl_admin get --raw=/readyz >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done
  return 1
}

require_role() {
  if [[ -z "${ROLE}" ]]; then
    echo "Usage: $0 master|worker [join_command_for_worker]"
    exit 1
  fi
  if [[ "${ROLE}" != "master" && "${ROLE}" != "worker" ]]; then
    echo "Role must be 'master' or 'worker'"
    exit 1
  fi
}

disable_swap() {
  log "Disabling swap"
  sudo swapoff -a
  if [[ -f /etc/fstab ]]; then
    sudo sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
  fi
}

install_docker() {
  log "Installing Docker"
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
  fi
  sudo systemctl enable --now docker
}

install_cri_dockerd() {
  log "Installing cri-dockerd"
  if ! command -v cri-dockerd >/dev/null 2>&1; then
    local ver
    ver="$(curl -fsSL https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest | awk -F '"' '/tag_name/{print $4}' | sed 's/^v//')"
    curl -fL "https://github.com/Mirantis/cri-dockerd/releases/download/v${ver}/cri-dockerd-${ver}.amd64.tgz" -o "/tmp/cri-dockerd-${ver}.amd64.tgz"
    tar -xzf "/tmp/cri-dockerd-${ver}.amd64.tgz" -C /tmp
    sudo mv /tmp/cri-dockerd/cri-dockerd /usr/local/bin/
  fi

  sudo curl -fsSL https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service -o /etc/systemd/system/cri-docker.service
  sudo curl -fsSL https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket -o /etc/systemd/system/cri-docker.socket
  sudo sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service

  sudo systemctl daemon-reload
  sudo systemctl enable --now cri-docker.socket
  sudo systemctl restart docker cri-docker
}

configure_cgroup_and_kernel() {
  log "Configuring Docker cgroup and kernel params"
  sudo mkdir -p /etc/docker
  cat <<'EOF' | sudo tee /etc/docker/daemon.json >/dev/null
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
  sudo systemctl restart docker cri-docker

  cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
br_netfilter
EOF
  cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
  sudo modprobe br_netfilter || true
  sudo sysctl --system
}

install_k8s_packages() {
  log "Installing kubelet/kubeadm/kubectl"

  # v1.26/v1.27 apt channel publishes an expired key in 2026.
  local repo_minor="${K8S_APT_REPO_MINOR:-${K8S_VERSION_MINOR}}"
  case "${repo_minor}" in
    v1.26|v1.27)
      log "Kubernetes apt repo ${repo_minor} has expired key, fallback to v1.28"
      repo_minor="v1.28"
      ;;
  esac

  # Remove stale Kubernetes apt entries from all apt source files.
  sudo bash -lc 'shopt -s nullglob; for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do [[ -f "$f" ]] || continue; sed -i -E "/pkgs\.k8s\.io|apt\.kubernetes\.io/d" "$f"; done'
  sudo rm -f /etc/apt/sources.list.d/kubernetes.list
  sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  # Clean stale cached indexes for old Kubernetes repo signatures.
  sudo bash -lc 'rm -f /var/lib/apt/lists/*pkgs.k8s.io* /var/lib/apt/lists/*kubernetes* || true'

  sudo apt-get update
  sudo apt-get install -y apt-transport-https ca-certificates curl gpg
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${repo_minor}/deb/Release.key" | gpg --dearmor | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.gpg >/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${repo_minor}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  if ! sudo apt-get update; then
    log "apt update failed once, refreshing Kubernetes apt key and retrying"
    sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${repo_minor}/deb/Release.key" | gpg --dearmor | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.gpg >/dev/null
    sudo apt-get update
  fi
  sudo apt-get install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl
}

setup_master_cluster() {
  log "Initializing Kubernetes control-plane"
  if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    local init_cmd=(
      sudo kubeadm init
      --pod-network-cidr 192.168.0.0/16
      --service-cidr 10.96.0.0/12
      --cri-socket "${CRI_SOCKET}"
    )
    if [[ -n "${MASTER_IP}" ]]; then
      init_cmd+=(--apiserver-advertise-address "${MASTER_IP}")
    fi
    "${init_cmd[@]}"
  else
    log "Detected existing /etc/kubernetes/admin.conf, skip kubeadm init"
    # Existing admin.conf does not guarantee API server is healthy.
    sudo systemctl restart kubelet || true
  fi

  if ! wait_for_apiserver 45 2; then
    echo "Control-plane API server is not reachable at https://${MASTER_IP:-127.0.0.1}:6443"
    echo "If this node is in a broken previous state, run:"
    echo "  sudo kubeadm reset -f"
    echo "Then rerun setup."
    exit 1
  fi

  local target_user target_group target_home
  target_user="${SUDO_USER:-$USER}"
  target_group="$(id -gn "${target_user}")"
  target_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  mkdir -p "${target_home}/.kube"
  sudo cp -f /etc/kubernetes/admin.conf "${target_home}/.kube/config"
  sudo chown "${target_user}:${target_group}" "${target_home}/.kube/config"

  export KUBECONFIG="${target_home}/.kube/config"

  local calico_path="${PROJECT_ROOT}/TopFull_master/calico.yaml"
  local cadvisor_dir="${PROJECT_ROOT}/TopFull_master/online_boutique_scripts/cadvisor"

  if [[ -f "${calico_path}" ]]; then
    log "Applying Calico CNI"
    kubectl_admin apply -f "${calico_path}"
  else
    log "WARNING: calico file not found at ${calico_path}"
  fi

  if [[ -d "${cadvisor_dir}" ]]; then
    log "Installing cAdvisor"
    (
      cd "${cadvisor_dir}"
      kubectl_admin kustomize deploy/kubernetes/base | kubectl_admin apply -f -
    )
  else
    log "WARNING: cadvisor directory not found at ${cadvisor_dir}"
  fi

  log "Master setup done. Use this join command on worker:"
  local join_cmd
  join_cmd="$(sudo kubeadm token create --print-join-command)"
  echo "${join_cmd} --cri-socket ${CRI_SOCKET}"
}

join_worker_cluster() {
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    log "Worker seems already joined (/etc/kubernetes/kubelet.conf exists), skip join"
    return
  fi
  if [[ -z "${JOIN_CMD_RAW}" ]]; then
    echo "For worker role, provide join command as 2nd arg or KUBEADM_JOIN_CMD env."
    echo "Example:"
    echo "  ./setup.sh worker \"kubeadm join ... --token ... --discovery-token-ca-cert-hash ...\""
    exit 1
  fi

  local cmd="${JOIN_CMD_RAW#sudo }"
  if [[ "${cmd}" != *"--cri-socket"* ]]; then
    cmd="${cmd} --cri-socket ${CRI_SOCKET}"
  fi

  log "Joining worker to cluster"
  sudo bash -lc "${cmd}"
}

main() {
  require_role
  disable_swap
  install_docker
  install_cri_dockerd
  configure_cgroup_and_kernel
  install_k8s_packages

  if [[ "${ROLE}" == "master" ]]; then
    setup_master_cluster
  else
    join_worker_cluster
  fi
}

main "$@"
