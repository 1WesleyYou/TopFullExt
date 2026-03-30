#!/usr/bin/env bash
set -euo pipefail

# Kubernetes Pod-level network delay injection via tcconfig (tcset/tcdel).
#
# Usage:
#   ./net_delay_k8s.sh set    # inject delay
#   ./net_delay_k8s.sh clear  # remove delay
#   ./net_delay_k8s.sh run    # timed inject + release + cleanup
#   ./net_delay_k8s.sh status # show current qdisc on targets

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Caller exports (e.g. run_b_tune_fast.sh) must survive `source .env`, which often sets NET_* to 0.
unset _CALL_NET_DELAY _CALL_INJECT _CALL_RELEASE
if [[ "${NET_DELAY_MS+isset}" == "isset" ]]; then _CALL_NET_DELAY="${NET_DELAY_MS}"; fi
if [[ "${NET_INJECT_AT_SEC+isset}" == "isset" ]]; then _CALL_INJECT="${NET_INJECT_AT_SEC}"; fi
if [[ "${NET_RELEASE_AT_SEC+isset}" == "isset" ]]; then _CALL_RELEASE="${NET_RELEASE_AT_SEC}"; fi

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

[[ "${_CALL_NET_DELAY+isset}" == "isset" ]] && NET_DELAY_MS="${_CALL_NET_DELAY}"
[[ "${_CALL_INJECT+isset}" == "isset" ]] && NET_INJECT_AT_SEC="${_CALL_INJECT}"
[[ "${_CALL_RELEASE+isset}" == "isset" ]] && NET_RELEASE_AT_SEC="${_CALL_RELEASE}"

ACTION="${1:-status}"
shift || true

MASTER_HOST="${MASTER_NODE:-node0}"
SSH_USER="${SSH_USER:-}"

NET_TARGET_SELECTOR="${NET_TARGET_SELECTOR:-}"
NET_TARGET_PODS="${NET_TARGET_PODS:-}"
# .env uses 0 for "no proxy tc"; for netem runs treat 0 like unset so timed defaults apply.
[[ -z "${NET_DELAY_MS:-}" || "${NET_DELAY_MS}"x == "0"x ]] && NET_DELAY_MS=200
NET_JITTER_MS="${NET_JITTER_MS:-0}"
NET_LOSS_PCT="${NET_LOSS_PCT:-0}"
NET_DIRECTION="${NET_DIRECTION:-egress}"
NET_NAMESPACE="${NET_NAMESPACE:-default}"
[[ -z "${NET_INJECT_AT_SEC:-}" || "${NET_INJECT_AT_SEC}"x == "0"x ]] && NET_INJECT_AT_SEC=60
[[ -z "${NET_RELEASE_AT_SEC:-}" || "${NET_RELEASE_AT_SEC}"x == "0"x ]] && NET_RELEASE_AT_SEC=180
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

# Default: accept node host keys on first connect (K8s nodes often differ from master SSH host).
# Override in .env: NET_SSH_OPTS="" to restore OpenSSH default, or add -i /path/to/key, etc.
: "${NET_SSH_OPTS=-o StrictHostKeyChecking=accept-new}"
ssh_tc() {
  # shellcheck disable=SC2086
  ssh ${NET_SSH_OPTS} "$@"
}

log() {
  printf "[%s] %s\n" "$(date +'%F %T')" "$*"
}

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

  ssh_tc "${MASTER_TARGET}" bash -s -- "${NET_NAMESPACE}" ${pods} <<'REMOTE_MAP'
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

# ---- tcconfig operations ----

apply_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  local node_target
  node_target="$(target_host "${node}")"

  ssh_tc "${node_target}" bash -s -- "${cid}" "${NET_IFACE}" "${NET_DELAY_MS}" "${NET_JITTER_MS}" "${NET_LOSS_PCT}" "${NET_DIRECTION}" <<'REMOTE_APPLY'
set -euo pipefail
cid="${1:?}"
iface="${2:?}"
delay_ms="${3:-200}"
jitter_ms="${4:-0}"
loss_pct="${5:-0}"
direction="${6:-egress}"

pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
fi
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  echo "WARN: cannot resolve PID for container ${cid}" >&2
  exit 0
fi

tcset_bin="${HOME}/.local/bin/tcset"
tcdel_bin="${HOME}/.local/bin/tcdel"
if [[ ! -x "${tcset_bin}" ]]; then
  tcset_bin="$(command -v tcset || true)"
fi
if [[ ! -x "${tcdel_bin}" ]]; then
  tcdel_bin="$(command -v tcdel || true)"
fi
if [[ -z "${tcset_bin}" || -z "${tcdel_bin}" ]]; then
  echo "ERROR: tcconfig(tcset/tcdel) not found on node (expected ~/.local/bin/tcset)" >&2
  exit 1
fi

sudo nsenter -t "${pid}" -n "${tcdel_bin}" "${iface}" --all >/dev/null 2>&1 || true

tcset_base=(sudo nsenter -t "${pid}" -n "${tcset_bin}" "${iface}" --delay "${delay_ms}ms" --overwrite)
if [[ "${jitter_ms}" != "0" ]]; then
  tcset_base+=(--delay-distro "${jitter_ms}ms")
fi
if [[ "${loss_pct}" != "0" ]]; then
  tcset_base+=(--loss "${loss_pct}")
fi

case "${direction}" in
  egress) "${tcset_base[@]}" --direction outgoing ;;
  ingress) "${tcset_base[@]}" --direction incoming ;;
  both) "${tcset_base[@]}" --direction outgoing; "${tcset_base[@]}" --direction incoming ;;
  *) echo "WARN: unsupported direction=${direction}, fallback to egress" >&2; "${tcset_base[@]}" --direction outgoing ;;
esac
REMOTE_APPLY
  log "  applied delay on pod=${pod} node=${node} (${NET_DELAY_MS}ms +${NET_JITTER_MS}ms jitter, ${NET_LOSS_PCT}% loss, ${NET_DIRECTION}, engine=tcconfig)"
}

clear_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  local node_target
  node_target="$(target_host "${node}")"

  ssh_tc "${node_target}" bash -s -- "${cid}" "${NET_IFACE}" <<'REMOTE_CLEAR'
set -euo pipefail
cid="${1:?}"; iface="${2:?}"
pid="$(sudo docker inspect -f '{{.State.Pid}}' "${cid}" 2>/dev/null || true)"
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  pid="$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null || true)"
fi
if [[ -z "${pid}" || "${pid}" == "0" ]]; then
  exit 0
fi
tcdel_bin="${HOME}/.local/bin/tcdel"
if [[ ! -x "${tcdel_bin}" ]]; then
  tcdel_bin="$(command -v tcdel || true)"
fi
if [[ -z "${tcdel_bin}" ]]; then
  echo "ERROR: tcdel not found on node (expected ~/.local/bin/tcdel)" >&2
  exit 1
fi
sudo nsenter -t "${pid}" -n "${tcdel_bin}" "${iface}" --all >/dev/null 2>&1 || true
REMOTE_CLEAR
  log "  cleared tcconfig rules on pod=${pod} node=${node}"
}

show_netem_on_pod() {
  local node="$1" cid="$2" pod="$3"
  local node_target
  node_target="$(target_host "${node}")"

  local output
  output="$(ssh_tc "${node_target}" bash -s -- "${cid}" "${NET_IFACE}" <<'REMOTE_SHOW'
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

  log "Applying tcconfig rules (delay=${NET_DELAY_MS}ms jitter=${NET_JITTER_MS}ms loss=${NET_LOSS_PCT}% direction=${NET_DIRECTION})..."
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

  log "Clearing tcconfig rules..."
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

  echo "========== qdisc status =========="
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
