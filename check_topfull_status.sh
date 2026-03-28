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
LOADGEN_HOST="${LOADGEN_NODE:-node3}"
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

  section "Loadgen Runtime (${LOADGEN_HOST})"
  ssh "${loadgen_target}" "tmux ls 2>/dev/null | egrep 'topfull-loadgen|session1|session2|session3' || echo 'no loadgen tmux session found'; echo; pgrep -af locust >/dev/null && echo 'locust process: running' || echo 'locust process: not running'"

  section "Loadgen Target Config (${LOADGEN_HOST})"
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

  local net_selector="${NET_TARGET_SELECTOR:-}"
  local net_pods="${NET_TARGET_PODS:-}"
  local net_ns="${NET_NAMESPACE:-default}"
  local net_iface="${NET_IFACE:-eth0}"

  if [[ -n "${net_selector}" || -n "${net_pods}" ]]; then
    section "Network Delay Injection (netem)"
    echo "  selector: ${net_selector}"
    echo "  pods:     ${net_pods}"
    echo "  namespace: ${net_ns}"

    local target_pods=""
    if [[ -n "${net_selector}" ]]; then
      target_pods="$(ssh "${master_target}" "kubectl get pods -n '${net_ns}' -l '${net_selector}' -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{end}'" | xargs)"
    else
      target_pods="${net_pods}"
    fi

    if [[ -z "${target_pods}" ]]; then
      echo "  (no matching pods found)"
    else
      for pod in ${target_pods}; do
        local node cid pid_info
        node="$(ssh "${master_target}" "kubectl get pod -n '${net_ns}' '${pod}' -o jsonpath='{.spec.nodeName}' 2>/dev/null" || true)"
        cid="$(ssh "${master_target}" "kubectl get pod -n '${net_ns}' '${pod}' -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null" || true)"
        cid="${cid#docker://}"
        cid="${cid#containerd://}"

        if [[ -n "${node}" && -n "${cid}" ]]; then
          local node_tgt
          node_tgt="$(target_host "${node}")"
          local qdisc_out
          qdisc_out="$(ssh "${node_tgt}" bash -s -- "${cid}" "${net_iface}" <<'NETEM_CHECK'
cid="${1:?}"; iface="${2:?}"
pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
fi
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  echo "(cannot resolve PID)"
  exit 0
fi
sudo nsenter -t "${pid}" -n tc qdisc show dev "${iface}" 2>/dev/null || echo "(no qdisc)"
NETEM_CHECK
)" || true
          echo "  ${pod} [${node}]: ${qdisc_out}"
        else
          echo "  ${pod}: (cannot resolve node/container)"
        fi
      done
    fi
  fi

}

main "$@"
