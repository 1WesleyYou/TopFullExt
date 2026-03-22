#!/usr/bin/env bash
set -euo pipefail

# Kubernetes Pod-level network delay injection via tc/netem.
#
# Usage:
#   ./net_delay_k8s.sh set    # inject delay
#   ./net_delay_k8s.sh clear  # remove delay
#   ./net_delay_k8s.sh run    # timed inject + release + cleanup
#   ./net_delay_k8s.sh status # show current netem qdisc on targets

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

ACTION="${1:-status}"
shift || true

MASTER_HOST="${MASTER_NODE:-node0}"
SSH_USER="${SSH_USER:-}"

NET_TARGET_SELECTOR="${NET_TARGET_SELECTOR:-}"
NET_TARGET_PODS="${NET_TARGET_PODS:-}"
NET_DELAY_MS="${NET_DELAY_MS:-200}"
NET_JITTER_MS="${NET_JITTER_MS:-0}"
NET_LOSS_PCT="${NET_LOSS_PCT:-0}"
NET_DIRECTION="${NET_DIRECTION:-egress}"
NET_NAMESPACE="${NET_NAMESPACE:-default}"
NET_INJECT_AT_SEC="${NET_INJECT_AT_SEC:-60}"
NET_RELEASE_AT_SEC="${NET_RELEASE_AT_SEC:-180}"
NET_CLEAR_ON_EXIT="${NET_CLEAR_ON_EXIT:-1}"
NET_IFACE="${NET_IFACE:-eth0}"

_INJECT_MARKER="$(mktemp -t net_delay_k8s.XXXXXX)"
_INJECT_PID=""
_RELEASE_PID=""
_RESOLVED_PODS_FILE="$(mktemp -t net_delay_pods.XXXXXX)"

target_host() {
  if [[ -n "${SSH_USER}" ]]; then
    printf "%s@%s" "${SSH_USER}" "$1"
  else
    printf "%s" "$1"
  fi
}

MASTER_TARGET="$(target_host "${MASTER_HOST}")"

log() {
  printf "[%s] %s\n" "$(date +'%F %T')" "$*"
}

# ---- Pod resolution ----

resolve_pods() {
  local pods=""
  if [[ -n "${NET_TARGET_SELECTOR}" ]]; then
    pods="$(ssh "${MASTER_TARGET}" \
      "kubectl get pods -n '${NET_NAMESPACE}' -l '${NET_TARGET_SELECTOR}' \
       -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{end}'" | xargs)"
  elif [[ -n "${NET_TARGET_PODS}" ]]; then
    pods="${NET_TARGET_PODS}"
  else
    echo "ERROR: set NET_TARGET_SELECTOR or NET_TARGET_PODS" >&2
    exit 1
  fi
  if [[ -z "${pods}" ]]; then
    echo "ERROR: no pods matched selector='${NET_TARGET_SELECTOR}' pods='${NET_TARGET_PODS}'" >&2
    exit 1
  fi
  printf '%s' "${pods}" > "${_RESOLVED_PODS_FILE}"
  echo "${pods}"
}

get_pod_node_container_map() {
  local pods="$1"

  ssh "${MASTER_TARGET}" bash -s -- "${NET_NAMESPACE}" ${pods} <<'REMOTE_MAP'
set -euo pipefail
ns="${1:?}"
shift
for pod in "$@"; do
  node="$(kubectl get pod -n "${ns}" "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  cid="$(kubectl get pod -n "${ns}" "${pod}" \
    -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null || true)"
  cid="${cid#docker://}"
  cid="${cid#containerd://}"
  if [[ -n "${node}" && -n "${cid}" ]]; then
    echo "${pod} ${node} ${cid}"
  fi
done
REMOTE_MAP
}

# ---- tc/netem operations ----

apply_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  local node_target
  node_target="$(target_host "${node}")"

  local delay_arg="delay ${NET_DELAY_MS}ms"
  if [[ "${NET_JITTER_MS}" != "0" ]]; then
    delay_arg="${delay_arg} ${NET_JITTER_MS}ms"
  fi
  local loss_arg=""
  if [[ "${NET_LOSS_PCT}" != "0" ]]; then
    loss_arg="loss ${NET_LOSS_PCT}%"
  fi

  ssh "${node_target}" bash -s -- "${cid}" "${NET_IFACE}" "${delay_arg}" "${loss_arg}" "${NET_DIRECTION}" <<'REMOTE_APPLY'
set -euo pipefail
cid="${1:?}"; iface="${2:?}"; delay_arg="${3}"; loss_arg="${4}"; direction="${5:-egress}"

pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
fi
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  echo "WARN: cannot resolve PID for container ${cid}" >&2
  exit 0
fi

apply_qdisc() {
  sudo nsenter -t "${pid}" -n tc qdisc del dev "${iface}" root 2>/dev/null || true
  sudo nsenter -t "${pid}" -n tc qdisc add dev "${iface}" root netem ${delay_arg} ${loss_arg}
}

apply_ingress_qdisc() {
  sudo nsenter -t "${pid}" -n tc qdisc del dev "${iface}" ingress 2>/dev/null || true
  sudo nsenter -t "${pid}" -n tc qdisc add dev "${iface}" handle ffff: ingress 2>/dev/null || true
  sudo nsenter -t "${pid}" -n tc filter del dev "${iface}" parent ffff: 2>/dev/null || true
  sudo nsenter -t "${pid}" -n ip link add ifb0 type ifb 2>/dev/null || true
  sudo nsenter -t "${pid}" -n ip link set ifb0 up 2>/dev/null || true
  sudo nsenter -t "${pid}" -n tc qdisc del dev ifb0 root 2>/dev/null || true
  sudo nsenter -t "${pid}" -n tc qdisc add dev ifb0 root netem ${delay_arg} ${loss_arg}
  sudo nsenter -t "${pid}" -n tc filter add dev "${iface}" parent ffff: \
    protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
}

case "${direction}" in
  egress)   apply_qdisc ;;
  ingress)  apply_ingress_qdisc ;;
  both)     apply_qdisc; apply_ingress_qdisc ;;
esac
REMOTE_APPLY
  log "  applied netem on pod=${pod} node=${node} (${NET_DELAY_MS}ms +${NET_JITTER_MS}ms jitter, ${NET_LOSS_PCT}% loss, ${NET_DIRECTION})"
}

clear_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  local node_target
  node_target="$(target_host "${node}")"

  ssh "${node_target}" bash -s -- "${cid}" "${NET_IFACE}" <<'REMOTE_CLEAR'
set -euo pipefail
cid="${1:?}"; iface="${2:?}"
pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
fi
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  exit 0
fi
sudo nsenter -t "${pid}" -n tc qdisc del dev "${iface}" root 2>/dev/null || true
sudo nsenter -t "${pid}" -n tc qdisc del dev "${iface}" ingress 2>/dev/null || true
sudo nsenter -t "${pid}" -n ip link del ifb0 2>/dev/null || true
REMOTE_CLEAR
  log "  cleared netem on pod=${pod} node=${node}"
}

show_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  local node_target
  node_target="$(target_host "${node}")"

  local output
  output="$(ssh "${node_target}" bash -s -- "${cid}" "${NET_IFACE}" <<'REMOTE_SHOW'
set -euo pipefail
cid="${1:?}"; iface="${2:?}"
pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
fi
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  echo "(cannot resolve container PID)"
  exit 0
fi
sudo nsenter -t "${pid}" -n tc qdisc show dev "${iface}" 2>/dev/null || echo "(no qdisc)"
REMOTE_SHOW
)" || true
  echo "  pod=${pod} node=${node}: ${output}"
}

# ---- High-level actions ----

do_set() {
  log "Resolving target pods..."
  local pods
  pods="$(resolve_pods)"
  log "Target pods: ${pods}"

  local map_output
  map_output="$(get_pod_node_container_map "${pods}")"
  if [[ -z "${map_output}" ]]; then
    log "ERROR: failed to resolve pod -> node/container mapping"
    exit 1
  fi

  log "Applying netem rules (delay=${NET_DELAY_MS}ms jitter=${NET_JITTER_MS}ms loss=${NET_LOSS_PCT}% direction=${NET_DIRECTION})..."
  while IFS=' ' read -r pod node cid; do
    apply_netem_on_pod "${node}" "${cid}" "${pod}"
  done <<< "${map_output}"

  date > "${_INJECT_MARKER}"
  log "Network delay injection active."
}

do_clear() {
  log "Resolving target pods..."
  local pods
  pods="$(resolve_pods)"
  log "Target pods: ${pods}"

  local map_output
  map_output="$(get_pod_node_container_map "${pods}")"
  if [[ -z "${map_output}" ]]; then
    log "No pods resolved for clear (may already be gone)"
    return 0
  fi

  log "Clearing netem rules..."
  while IFS=' ' read -r pod node cid; do
    clear_netem_on_pod "${node}" "${cid}" "${pod}"
  done <<< "${map_output}"

  : > "${_INJECT_MARKER}"
  log "Network delay cleared."
}

do_status() {
  log "Resolving target pods..."
  local pods
  pods="$(resolve_pods)"
  log "Target pods: ${pods}"

  local map_output
  map_output="$(get_pod_node_container_map "${pods}")"
  if [[ -z "${map_output}" ]]; then
    log "No pods resolved"
    return 0
  fi

  echo "========== netem qdisc status =========="
  while IFS=' ' read -r pod node cid; do
    show_netem_on_pod "${node}" "${cid}" "${pod}"
  done <<< "${map_output}"
}

# ---- Timed run mode ----

cleanup_on_exit() {
  if [[ -n "${_INJECT_PID}" ]]; then
    kill "${_INJECT_PID}" 2>/dev/null || true
    wait "${_INJECT_PID}" 2>/dev/null || true
  fi
  if [[ -n "${_RELEASE_PID}" ]]; then
    kill "${_RELEASE_PID}" 2>/dev/null || true
    wait "${_RELEASE_PID}" 2>/dev/null || true
  fi
  if [[ "${NET_CLEAR_ON_EXIT}" == "1" && -s "${_INJECT_MARKER}" ]]; then
    log "Exit cleanup: clearing netem rules..."
    do_clear || log "WARN: cleanup failed"
  fi
  rm -f "${_INJECT_MARKER}" "${_RESOLVED_PODS_FILE}" 2>/dev/null || true
}

do_run() {
  trap cleanup_on_exit EXIT INT TERM

  log "Timed run mode: inject at ${NET_INJECT_AT_SEC}s, release at ${NET_RELEASE_AT_SEC}s"
  log "  selector=${NET_TARGET_SELECTOR} pods=${NET_TARGET_PODS}"
  log "  delay=${NET_DELAY_MS}ms jitter=${NET_JITTER_MS}ms loss=${NET_LOSS_PCT}%"
  log "  direction=${NET_DIRECTION} namespace=${NET_NAMESPACE}"

  (
    sleep "${NET_INJECT_AT_SEC}"
    log "[timed] Injecting network delay at t=${NET_INJECT_AT_SEC}s..."
    do_set
  ) &
  _INJECT_PID="$!"

  if [[ "${NET_RELEASE_AT_SEC}" -gt 0 ]]; then
    (
      sleep "${NET_RELEASE_AT_SEC}"
      log "[timed] Releasing network delay at t=${NET_RELEASE_AT_SEC}s..."
      do_clear
    ) &
    _RELEASE_PID="$!"
  fi

  log "Waiting for timed operations to complete (Ctrl+C to abort and auto-clear)..."
  wait "${_INJECT_PID}" 2>/dev/null || true
  _INJECT_PID=""
  if [[ -n "${_RELEASE_PID}" ]]; then
    wait "${_RELEASE_PID}" 2>/dev/null || true
    _RELEASE_PID=""
  fi

  log "Timed run completed."
}

# ---- Main dispatch ----

case "${ACTION}" in
  set)    do_set ;;
  clear)  do_clear ;;
  status) do_status ;;
  run)    do_run ;;
  *)
    echo "Usage: $0 {set|clear|status|run}"
    echo ""
    echo "  set    - inject network delay on target pods"
    echo "  clear  - remove network delay from target pods"
    echo "  status - show current netem qdisc on target pods"
    echo "  run    - timed inject at NET_INJECT_AT_SEC, release at NET_RELEASE_AT_SEC"
    echo ""
    echo "Environment variables:"
    echo "  NET_TARGET_SELECTOR   label selector (e.g. app=productcatalogservice)"
    echo "  NET_TARGET_PODS       explicit pod names (space-separated)"
    echo "  NET_DELAY_MS          delay in ms (default: 200)"
    echo "  NET_JITTER_MS         jitter in ms (default: 0)"
    echo "  NET_LOSS_PCT          packet loss % (default: 0)"
    echo "  NET_DIRECTION         egress|ingress|both (default: egress)"
    echo "  NET_NAMESPACE         k8s namespace (default: default)"
    echo "  NET_INJECT_AT_SEC     seconds before inject in run mode (default: 60)"
    echo "  NET_RELEASE_AT_SEC    seconds before release in run mode (default: 180)"
    echo "  NET_CLEAR_ON_EXIT     auto-clear on exit 1/0 (default: 1)"
    echo "  NET_IFACE             pod network interface (default: eth0)"
    exit 1
    ;;
esac
