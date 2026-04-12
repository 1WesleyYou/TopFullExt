#!/usr/bin/env bash
set -euo pipefail

# Kubernetes Pod-level network fault injection via tcconfig (tcset/tcdel).
#
# Usage:
#   NET_DELAY_MS=30 NET_LOSS_PCT=10 NET_DIRECTION=both ./net_delay_k8s.sh set
#   ./net_delay_k8s.sh clear
#   ./net_delay_k8s.sh status
#
# Env vars (all read directly, no .env override magic):
#   NET_TARGET_SELECTOR   label selector (e.g. app=productcatalogservice)
#   NET_TARGET_PODS       explicit pod names (space-separated)
#   NET_DELAY_MS          delay in ms       (default: 0)
#   NET_JITTER_MS         jitter in ms      (default: 0)
#   NET_LOSS_PCT          packet loss %     (default: 0)
#   NET_DIRECTION         egress|ingress|both (default: both)
#   NET_NAMESPACE         k8s namespace     (default: default)
#   NET_IFACE             pod interface     (default: eth0)
#   NET_TARGET_POD_COUNT  truncate resolved pod list to first N (default: 0 = all)
#   MASTER_NODE           master host       (default: node0)
#   SSH_USER              ssh user prefix   (default: empty)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Source .env only for infra vars (MASTER_NODE, SSH_USER, NET_TARGET_SELECTOR, etc).
# Caller-exported NET_DELAY_MS / NET_LOSS_PCT / NET_DIRECTION always win.
_save_delay="${NET_DELAY_MS:-}"; _save_jitter="${NET_JITTER_MS:-}"
_save_loss="${NET_LOSS_PCT:-}"; _save_dir="${NET_DIRECTION:-}"
_save_count="${NET_TARGET_POD_COUNT:-}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi
NET_DELAY_MS="${_save_delay}"; NET_JITTER_MS="${_save_jitter}"
NET_LOSS_PCT="${_save_loss}"; NET_DIRECTION="${_save_dir}"
NET_TARGET_POD_COUNT="${_save_count}"
unset _save_delay _save_jitter _save_loss _save_dir _save_count

ACTION="${1:-status}"
shift || true

MASTER_HOST="${MASTER_NODE:-node0}"
SSH_USER="${SSH_USER:-}"
NET_TARGET_SELECTOR="${NET_TARGET_SELECTOR:-}"
NET_TARGET_PODS="${NET_TARGET_PODS:-}"
NET_DELAY_MS="${NET_DELAY_MS:-0}"
NET_JITTER_MS="${NET_JITTER_MS:-0}"
NET_LOSS_PCT="${NET_LOSS_PCT:-0}"
NET_DIRECTION="${NET_DIRECTION:-both}"
NET_NAMESPACE="${NET_NAMESPACE:-default}"
NET_IFACE="${NET_IFACE:-eth0}"
NET_TARGET_POD_COUNT="${NET_TARGET_POD_COUNT:-0}"   # 0 = inject all matching pods; N>0 = take first N

target_host() {
  if [[ -n "${SSH_USER}" ]]; then printf "%s@%s" "${SSH_USER}" "$1"; else printf "%s" "$1"; fi
}
MASTER_TARGET="$(target_host "${MASTER_HOST}")"

: "${NET_SSH_OPTS=-o StrictHostKeyChecking=accept-new}"
ssh_tc() { ssh ${NET_SSH_OPTS} "$@"; }

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }

# ---- Pod resolution ----

resolve_pods() {
  local pods=""
  if [[ -n "${NET_TARGET_SELECTOR}" ]]; then
    pods="$(ssh_tc "${MASTER_TARGET}" \
      "kubectl get pods -n '${NET_NAMESPACE}' -l '${NET_TARGET_SELECTOR}' \
       -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{end}'" | xargs)"
  elif [[ -n "${NET_TARGET_PODS}" ]]; then
    pods="${NET_TARGET_PODS}"
  else
    echo "ERROR: set NET_TARGET_SELECTOR or NET_TARGET_PODS" >&2; exit 1
  fi
  [[ -z "${pods}" ]] && { echo "ERROR: no pods matched" >&2; exit 1; }
  # Optional subset: when NET_TARGET_POD_COUNT > 0, truncate to first N (stable kubectl order).
  if [[ "${NET_TARGET_POD_COUNT}" -gt 0 ]]; then
    # shellcheck disable=SC2206
    local arr=( ${pods} )
    local total="${#arr[@]}"
    if [[ "${NET_TARGET_POD_COUNT}" -lt "${total}" ]]; then
      pods="${arr[*]:0:${NET_TARGET_POD_COUNT}}"
    fi
  fi
  echo "${pods}"
}

get_pod_node_container_map() {
  local pods="$1"
  ssh_tc "${MASTER_TARGET}" bash -s -- "${NET_NAMESPACE}" ${pods} <<'REMOTE_MAP'
set -euo pipefail
ns="${1:?}"; shift
for pod in "$@"; do
  node="$(kubectl get pod -n "${ns}" "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  cid="$(kubectl get pod -n "${ns}" "${pod}" -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null || true)"
  cid="${cid#docker://}"; cid="${cid#containerd://}"
  [[ -n "${node}" && -n "${cid}" ]] && echo "${pod} ${node} ${cid}"
done
REMOTE_MAP
}

# ---- tcconfig operations ----

apply_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  ssh_tc "$(target_host "${node}")" bash -s -- "${cid}" "${NET_IFACE}" "${NET_DELAY_MS}" "${NET_JITTER_MS}" "${NET_LOSS_PCT}" "${NET_DIRECTION}" <<'REMOTE_APPLY'
set -euo pipefail
cid="${1:?}"; iface="${2:?}"; delay_ms="${3:-0}"; jitter_ms="${4:-0}"; loss_pct="${5:-0}"; direction="${6:-both}"
pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
[[ -z "${pid}" || "${pid}" == "0" ]] && pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
[[ -z "${pid}" || "${pid}" == "0" ]] && { echo "WARN: cannot resolve PID for ${cid}" >&2; exit 0; }
tcset_bin="${HOME}/.local/bin/tcset"; [[ ! -x "${tcset_bin}" ]] && tcset_bin="$(command -v tcset || true)"
tcdel_bin="${HOME}/.local/bin/tcdel"; [[ ! -x "${tcdel_bin}" ]] && tcdel_bin="$(command -v tcdel || true)"
[[ -z "${tcset_bin}" || -z "${tcdel_bin}" ]] && { echo "ERROR: tcconfig not found" >&2; exit 1; }
sudo nsenter -t "${pid}" -n "${tcdel_bin}" "${iface}" --all >/dev/null 2>&1 || true
cmd=(sudo nsenter -t "${pid}" -n "${tcset_bin}" "${iface}" --overwrite)
[[ "${delay_ms}" != "0" ]] && cmd+=(--delay "${delay_ms}ms")
[[ "${jitter_ms}" != "0" ]] && cmd+=(--delay-distro "${jitter_ms}ms")
[[ "${loss_pct}" != "0" ]] && cmd+=(--loss "${loss_pct}")
case "${direction}" in
  egress)  "${cmd[@]}" --direction outgoing ;;
  ingress) "${cmd[@]}" --direction incoming ;;
  both)    "${cmd[@]}" --direction outgoing; "${cmd[@]}" --direction incoming ;;
esac
REMOTE_APPLY
  log "  applied on pod=${pod} node=${node} (${NET_DELAY_MS}ms delay, ${NET_LOSS_PCT}% loss, ${NET_DIRECTION})"
}

clear_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  ssh_tc "$(target_host "${node}")" bash -s -- "${cid}" "${NET_IFACE}" <<'REMOTE_CLEAR'
set -euo pipefail
cid="${1:?}"; iface="${2:?}"
pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
[[ -z "${pid}" || "${pid}" == "0" ]] && pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
[[ -z "${pid}" || "${pid}" == "0" ]] && exit 0
tcdel_bin="${HOME}/.local/bin/tcdel"; [[ ! -x "${tcdel_bin}" ]] && tcdel_bin="$(command -v tcdel || true)"
[[ -z "${tcdel_bin}" ]] && { echo "ERROR: tcdel not found" >&2; exit 1; }
for _pass in 1 2; do
  sudo nsenter -t "${pid}" -n "${tcdel_bin}" "${iface}" --all >/dev/null 2>&1 || true
  sleep 1
done
REMOTE_CLEAR
  log "  cleared on pod=${pod} node=${node}"
}

show_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  local output
  output="$(ssh_tc "$(target_host "${node}")" bash -s -- "${cid}" "${NET_IFACE}" <<'REMOTE_SHOW'
set -euo pipefail
cid="${1:?}"; iface="${2:?}"
pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
[[ -z "${pid}" || "${pid}" == "0" ]] && pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
[[ -z "${pid}" || "${pid}" == "0" ]] && { echo "(cannot resolve PID)"; exit 0; }
sudo nsenter -t "${pid}" -n tc qdisc show dev "${iface}" 2>/dev/null || echo "(no qdisc)"
REMOTE_SHOW
)" || true
  echo "  pod=${pod} node=${node}: ${output}"
}

# ---- High-level actions ----

do_set() {
  if [[ "${NET_DELAY_MS}" == "0" && "${NET_JITTER_MS}" == "0" && "${NET_LOSS_PCT}" == "0" ]]; then
    log "Nothing to inject (delay/jitter/loss all zero); skipping."
    return 0
  fi
  log "Resolving target pods..."
  local pods; pods="$(resolve_pods)"; log "Target pods: ${pods}"
  local map; map="$(get_pod_node_container_map "${pods}")"
  [[ -z "${map}" ]] && { log "ERROR: no pod->node mapping"; exit 1; }
  log "Applying (delay=${NET_DELAY_MS}ms loss=${NET_LOSS_PCT}% direction=${NET_DIRECTION})..."
  while IFS=' ' read -r pod node cid; do
    apply_netem_on_pod "${node}" "${cid}" "${pod}"
  done <<< "${map}"
  log "Injection active."
}

do_clear() {
  log "Resolving target pods..."
  local pods; pods="$(resolve_pods)"; log "Target pods: ${pods}"
  local map; map="$(get_pod_node_container_map "${pods}")"
  [[ -z "${map}" ]] && { log "No pods to clear"; return 0; }
  log "Clearing tcconfig rules..."
  while IFS=' ' read -r pod node cid; do
    clear_netem_on_pod "${node}" "${cid}" "${pod}"
  done <<< "${map}"
  log "Cleared."
}

do_status() {
  log "Resolving target pods..."
  local pods; pods="$(resolve_pods)"; log "Target pods: ${pods}"
  local map; map="$(get_pod_node_container_map "${pods}")"
  [[ -z "${map}" ]] && { log "No pods"; return 0; }
  echo "========== qdisc status =========="
  while IFS=' ' read -r pod node cid; do
    show_netem_on_pod "${node}" "${cid}" "${pod}"
  done <<< "${map}"
}

# ---- Dispatch ----

case "${ACTION}" in
  set)    do_set ;;
  clear)  do_clear ;;
  status) do_status ;;
  *)
    echo "Usage: $0 {set|clear|status}"
    echo "  Env: NET_DELAY_MS  NET_LOSS_PCT  NET_DIRECTION  NET_TARGET_SELECTOR  NET_IFACE"
    exit 1
    ;;
esac
