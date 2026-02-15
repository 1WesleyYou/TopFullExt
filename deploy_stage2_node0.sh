#!/usr/bin/env bash
set -euo pipefail

# Stage 2 deploy script (run on node0/master).
# It applies Online Boutique + metrics-server, then scales down for single worker.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

PROJECT_ROOT="${PROJECT_ROOT:-${HOME}/TopFullExt}"
TOPFULL_DEPLOY_DIR="${TOPFULL_DEPLOY_DIR:-${PROJECT_ROOT}/TopFull_master/online_boutique_scripts/deployments}"
MASTER_IP="${MASTER_IP:-$(hostname -I | awk '{print $1}')}"
FRONTEND_NODEPORT="${FRONTEND_NODEPORT:-30440}"

ONLINE_BOUTIQUE_YAML="${TOPFULL_DEPLOY_DIR}/online_boutique_original_custom.yaml"
METRIC_SERVER_YAML="${TOPFULL_DEPLOY_DIR}/metric-server-latest.yaml"

log() {
  printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1"
    exit 1
  }
}

apply_manifests() {
  log "Applying Online Boutique manifest"
  kubectl apply -f "${ONLINE_BOUTIQUE_YAML}"

  log "Applying metrics-server manifest"
  kubectl apply -f "${METRIC_SERVER_YAML}"
}

scale_for_single_worker() {
  # Lower footprint for 1-worker setup.
  local services=(
    frontend
    recommendationservice
    currencyservice
    paymentservice
    productcatalogservice
    shippingservice
    redis-cart
    emailservice
    checkoutservice
    adservice
    cartservice
  )

  log "Scaling deployments for single-worker mode (all replicas=1)"
  for svc in "${services[@]}"; do
    kubectl scale deploy/"${svc}" --replicas=1 -n default
  done
}

wait_rollout() {
  local services=(
    frontend
    recommendationservice
    currencyservice
    paymentservice
    productcatalogservice
    shippingservice
    redis-cart
    emailservice
    checkoutservice
    adservice
    cartservice
  )

  log "Waiting for main deployments rollout"
  for svc in "${services[@]}"; do
    kubectl rollout status deploy/"${svc}" -n default --timeout=300s
  done

  log "Waiting for metrics-server rollout"
  kubectl rollout status deploy/metrics-server -n kube-system --timeout=300s || true
}

verify() {
  log "Pod status"
  kubectl get po -A -o wide

  log "Frontend service"
  kubectl get svc frontend -n default

  local frontend_url="http://${MASTER_IP}:${FRONTEND_NODEPORT}"
  log "Trying frontend NodePort: ${frontend_url}"
  if curl -fsS --max-time 5 "${frontend_url}" >/dev/null; then
    echo "Frontend reachable: ${frontend_url}"
  else
    echo "Frontend not reachable yet at ${frontend_url} (may still be warming up)."
    echo "Retry with: curl -I ${frontend_url}"
  fi
}

main() {
  require_cmd kubectl
  require_cmd curl
  if [[ ! -f "${ONLINE_BOUTIQUE_YAML}" || ! -f "${METRIC_SERVER_YAML}" ]]; then
    echo "Deployment yaml not found under ${TOPFULL_DEPLOY_DIR}"
    exit 1
  fi

  apply_manifests
  scale_for_single_worker
  wait_rollout
  verify
}

main "$@"
