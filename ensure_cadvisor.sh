#!/usr/bin/env bash
set -euo pipefail

# Ensure cAdvisor is deployed and ready on the master node.
# This script is safe to run repeatedly.

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
CADVISOR_READY_TIMEOUT_SEC="${CADVISOR_READY_TIMEOUT_SEC:-180}"

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

MASTER_REPO_DIR="$(resolve_remote_repo_dir)"

LOCAL_OVERLAY_DIR="${SCRIPT_DIR}/TopFull_master/online_boutique_scripts/cadvisor/deploy/kubernetes/overlays/allow-master"
REMOTE_OVERLAY_DIR="${MASTER_REPO_DIR}/TopFull_master/online_boutique_scripts/cadvisor/deploy/kubernetes/overlays/allow-master"

if [[ ! -d "${LOCAL_OVERLAY_DIR}" ]]; then
  echo "[cadvisor] ERROR: local overlay not found: ${LOCAL_OVERLAY_DIR}" >&2
  exit 1
fi

# Keep remote cadvisor overlay in sync even if remote repo is stale.
ssh "${MASTER_TARGET}" "mkdir -p \"${REMOTE_OVERLAY_DIR}\""
scp "${LOCAL_OVERLAY_DIR}/kustomization.yaml" "${MASTER_TARGET}:${REMOTE_OVERLAY_DIR}/kustomization.yaml"
scp "${LOCAL_OVERLAY_DIR}/tolerations-and-resources.yaml" "${MASTER_TARGET}:${REMOTE_OVERLAY_DIR}/tolerations-and-resources.yaml"

ssh "${MASTER_TARGET}" bash -s -- "${MASTER_REPO_DIR}" "${CADVISOR_READY_TIMEOUT_SEC}" <<'REMOTE'
set -euo pipefail
repo_dir="${1:?repo_dir required}"
timeout_sec="${2:-180}"

cadvisor_dir="${repo_dir}/TopFull_master/online_boutique_scripts/cadvisor"
overlay_dir="${cadvisor_dir}/deploy/kubernetes/overlays/allow-master"

if [[ ! -d "${cadvisor_dir}" ]]; then
  echo "[cadvisor] ERROR: directory not found: ${cadvisor_dir}" >&2
  exit 1
fi

if [[ ! -d "${overlay_dir}" ]]; then
  echo "[cadvisor] ERROR: overlay not found: ${overlay_dir}" >&2
  exit 1
fi

echo "[cadvisor] Applying overlay allow-master on ${HOSTNAME}..."
cd "${cadvisor_dir}"
kubectl get namespace cadvisor >/dev/null 2>&1 || kubectl create namespace cadvisor >/dev/null
kubectl kustomize deploy/kubernetes/overlays/allow-master | kubectl apply -f -

echo "[cadvisor] Waiting for daemonset rollout (timeout: ${timeout_sec}s)..."
set +e
kubectl rollout status daemonset/cadvisor -n cadvisor --timeout="${timeout_sec}s"
rollout_status=$?
set -e

running_count="$(kubectl get pod -n cadvisor --field-selector=status.phase=Running --no-headers 2>/dev/null | awk 'NF>0{c++} END{print c+0}')"
if [[ "${running_count}" -lt 1 ]]; then
  echo "[cadvisor] ERROR: no Running cAdvisor pod found." >&2
  kubectl get pod -n cadvisor -o wide || true
  pod_name="$(kubectl get pod -n cadvisor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod_name}" ]]; then
    kubectl describe pod -n cadvisor "${pod_name}" || true
  fi
  exit 1
fi

if [[ "${rollout_status}" -ne 0 ]]; then
  echo "[cadvisor] WARNING: daemonset not fully rolled out, but ${running_count} pod is Running. Continuing."
fi

echo "[cadvisor] Ready (${running_count} pod running)."
kubectl get pod -n cadvisor -o wide
REMOTE
