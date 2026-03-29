#!/usr/bin/env bash
set -euo pipefail

# Stop all TopFull experiments: kill controller stack on master and locust injection on loadgen.
# Run from coordinator node (e.g., node3).
#
# Usage:
#   ./stop_all.sh
#   make stop

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

MASTER_HOST="${MASTER_NODE:-node0}"
LOADGEN_HOST="${LOADGEN_NODE:-node3}"
SSH_USER="${SSH_USER:-}"

target_host() {
  local host="$1"
  if [[ -n "${SSH_USER}" ]]; then
    printf "%s@%s" "${SSH_USER}" "${host}"
  else
    printf "%s" "${host}"
  fi
}

main() {
  local master_target loadgen_target
  master_target="$(target_host "${MASTER_HOST}")"
  loadgen_target="$(target_host "${LOADGEN_HOST}")"

  echo "Stopping TopFull controller stack on ${master_target}..."
  ssh "${master_target}" "for s in topfull-proxy topfull-controller topfull-metrics; do tmux kill-session -t \$s 2>/dev/null || true; done; echo '  done.'; exit 0" || true

  echo "Stopping load injection (tmux + locust) on ${loadgen_target}..."
  ssh "${loadgen_target}" "for s in session1 session2 session3 session4 session5 session6 topfull-loadgen; do tmux kill-session -t \$s 2>/dev/null || true; done; pkill -f locust 2>/dev/null || true; echo '  done.'; exit 0" || true

  echo "All injection and controller processes stopped."

  echo "Rolling restart frontend to rebalance gRPC connections..."
  ssh "${master_target}" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl rollout restart deployment frontend -n default && sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl rollout status deployment frontend -n default --timeout=120s" 2>/dev/null && echo "Frontend rollout complete." || echo "Frontend rollout skipped (cluster may not be ready)."
}

main "$@"
