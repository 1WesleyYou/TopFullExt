#!/usr/bin/env bash
set -euo pipefail

# Check TopFull deployment status from a coordinator node (e.g., node3).
# It queries master/loadgen over SSH and prints key runtime status.
#
# Usage:
#   ./check_topfull_status.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

MASTER_HOST="${MASTER_NODE:-node0}"
LOADGEN_HOST="${LOADGEN_NODE:-node2}"
SSH_USER="${SSH_USER:-}"
MASTER_IP_VALUE="${MASTER_IP:-}"
FRONTEND_NODEPORT="${FRONTEND_NODEPORT:-30440}"

target_host() {
  local host="$1"
  if [[ -n "${SSH_USER}" ]]; then
    printf "%s@%s" "${SSH_USER}" "${host}"
  else
    printf "%s" "${host}"
  fi
}

section() {
  printf "\n========== %s ==========\n" "$1"
}

main() {
  local master_target loadgen_target
  master_target="$(target_host "${MASTER_HOST}")"
  loadgen_target="$(target_host "${LOADGEN_HOST}")"

  if [[ -z "${MASTER_IP_VALUE}" ]]; then
    MASTER_IP_VALUE="$(ssh "${master_target}" "hostname -I | awk '{print \$1}'" | tr -d '[:space:]')"
  fi

  echo "Master target : ${master_target}"
  echo "Loadgen target: ${loadgen_target}"
  echo "Master IP     : ${MASTER_IP_VALUE}"
  echo "Frontend port : ${FRONTEND_NODEPORT}"

  section "Application Service (master)"
  ssh "${master_target}" "kubectl get svc frontend -n default 2>/dev/null || echo 'frontend service not found'"
  ssh "${master_target}" "curl -fsSI --max-time 5 http://${MASTER_IP_VALUE}:${FRONTEND_NODEPORT} | sed -n '1,2p' || echo 'frontend not reachable from master'"

  section "TopFull Runtime (master)"
  ssh "${master_target}" "tmux ls 2>/dev/null | egrep 'topfull-proxy|topfull-controller|topfull-metrics|topfull-loadgen' || echo 'no topfull tmux session found'; echo; pgrep -af 'proxy_online_boutique|deploy_rl.py|deploy_mimd.py|deploy_without_cluster.py|metric_collector.py' || echo 'no topfull process found'"

  section "Loadgen Runtime (node2)"
  ssh "${loadgen_target}" "tmux ls 2>/dev/null | egrep 'topfull-loadgen|session1|session2|session3' || echo 'no loadgen tmux session found'; echo; pgrep -af locust >/dev/null && echo 'locust process: running' || echo 'locust process: not running'"

  section "Loadgen Target Config (node2)"
  ssh "${loadgen_target}" "python3 - <<'PY'
from pathlib import Path
import re
base = Path.home() / 'TopFullExt' / 'TopFull_loadgen'
for name in ('online_boutique_create.sh', 'online_boutique_create2.sh'):
    p = base / name
    if p.exists():
        txt = p.read_text()
        hosts = sorted(set(re.findall(r'--host=http://[0-9.]+:30440', txt)))
        print(f'{name}: {hosts}')
    else:
        print(f'{name}: missing')
p = base / 'locust_online_boutique.py'
if p.exists():
    txt = p.read_text()
    proxies = sorted(set(re.findall(r'http://[0-9.]+:8090', txt)))
    print(f'locust_online_boutique.py proxy: {proxies}')
else:
    print('locust_online_boutique.py: missing')
PY"
  ssh "${loadgen_target}" "curl -fsSI --max-time 5 http://${MASTER_IP_VALUE}:${FRONTEND_NODEPORT} | sed -n '1,2p' || echo 'frontend not reachable from loadgen'"

}

main "$@"
