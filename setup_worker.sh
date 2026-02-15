#!/usr/bin/env bash
set -euo pipefail

# Worker node (node1) one-command setup.
# Usage on node1:
#   cd ~/TopFullExt
#   # Set join command in .env, then:
#   ./setup_worker.sh
#
# Optionally hardcode here:
#   JOIN_CMD_FIXED="kubeadm join ... --token ... --discovery-token-ca-cert-hash ..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

JOIN_CMD_FIXED="${JOIN_CMD_FIXED:-}"
JOIN_CMD="${JOIN_CMD_FIXED:-${KUBEADM_JOIN_CMD:-}}"

if [[ -z "${JOIN_CMD}" ]]; then
  echo "Missing join command."
  echo "Set KUBEADM_JOIN_CMD in ${ENV_FILE}, or set JOIN_CMD_FIXED in setup_worker.sh."
  echo "Example:"
  echo "KUBEADM_JOIN_CMD=\"kubeadm join 10.10.1.1:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>\""
  exit 1
fi

"${SCRIPT_DIR}/setup.sh" worker "${JOIN_CMD}"
