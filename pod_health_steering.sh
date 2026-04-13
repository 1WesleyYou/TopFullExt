#!/usr/bin/env bash
set -euo pipefail

# Runtime pod health steering for productcatalogservice.
#
# Detects faulty pods via gRPC health probe (cross-pod exec), removes them
# from K8s Service endpoints (label removal), and flushes conntrack entries
# to force frontend gRPC clients to reconnect to healthy pods.
#
# Usage:
#   ./pod_health_steering.sh detect     # probe all pods, report health
#   ./pod_health_steering.sh steer      # detect + remove faulty from endpoints + flush conntrack
#   ./pod_health_steering.sh restore    # re-add all steered pods to endpoints
#   ./pod_health_steering.sh status     # show endpoint membership + conntrack counts
#   ./pod_health_steering.sh monitor    # continuous detect+steer loop (foreground)
#
# Env vars:
#   STEERING_INTERVAL=5            seconds between monitor cycles
#   STEERING_PROBE_TIMEOUT=2       gRPC health probe timeout (seconds)
#   STEERING_MIN_HEALTHY=1         never remove more pods than this threshold
#   STEERING_SERVICE_PORT=3550     productcatalogservice gRPC port
#   STEERING_CONNTRACK_NODES="node0 node1 node2"   nodes to flush conntrack on
#   STEERING_LOG=<script_dir>/steering_events.log
#   NET_TARGET_SELECTOR            label selector (from .env)
#   NET_NAMESPACE                  k8s namespace (from .env)
#   MASTER_NODE                    master node hostname (from .env)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Source .env for infra vars, preserving caller overrides.
_save_interval="${STEERING_INTERVAL:-}"
_save_timeout="${STEERING_PROBE_TIMEOUT:-}"
_save_min="${STEERING_MIN_HEALTHY:-}"
_save_port="${STEERING_SERVICE_PORT:-}"
_save_nodes="${STEERING_CONNTRACK_NODES:-}"
_save_log="${STEERING_LOG:-}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi
STEERING_INTERVAL="${_save_interval:-${STEERING_INTERVAL:-5}}"
STEERING_PROBE_TIMEOUT="${_save_timeout:-${STEERING_PROBE_TIMEOUT:-2}}"
STEERING_MIN_HEALTHY="${_save_min:-${STEERING_MIN_HEALTHY:-1}}"
STEERING_SERVICE_PORT="${_save_port:-${STEERING_SERVICE_PORT:-3550}}"
STEERING_CONNTRACK_NODES="${_save_nodes:-${STEERING_CONNTRACK_NODES:-node0 node1 node2}}"
STEERING_LOG="${_save_log:-${STEERING_LOG:-${SCRIPT_DIR}/steering_events.log}}"
unset _save_interval _save_timeout _save_min _save_port _save_nodes _save_log

ACTION="${1:-status}"
shift || true

MASTER_HOST="${MASTER_NODE:-node0}"
SSH_USER="${SSH_USER:-}"
NET_NAMESPACE="${NET_NAMESPACE:-default}"
NET_TARGET_SELECTOR="${NET_TARGET_SELECTOR:-app=productcatalogservice}"

STEERED_FILE="/tmp/steering_steered_pods.txt"

target_host() {
  if [[ -n "${SSH_USER}" ]]; then printf "%s@%s" "${SSH_USER}" "$1"; else printf "%s" "$1"; fi
}
MASTER_TARGET="$(target_host "${MASTER_HOST}")"

: "${NET_SSH_OPTS=-o StrictHostKeyChecking=accept-new}"
ssh_s() { ssh -n ${NET_SSH_OPTS} "$@"; }

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
ts()  { printf "[%s]" "$(date +'%H:%M:%S')"; }

# ---- Pod resolution ----

# Returns "pod_name pod_ip" lines for ALL productcatalogservice pods
# (including steered-away ones via the steered-file).
resolve_all_pods() {
  # 1. Get labeled pods (currently in endpoints).
  local labeled
  labeled="$(ssh_s "${MASTER_TARGET}" \
    "kubectl get pods -n '${NET_NAMESPACE}' -l '${NET_TARGET_SELECTOR}' \
     -o custom-columns='NAME:.metadata.name,IP:.status.podIP' --no-headers" 2>/dev/null \
    | awk 'NF==2 {print $1, $2}')"

  # 2. Merge with steered-away pods (still running, just missing app label).
  local all="${labeled}"
  if [[ -s "${STEERED_FILE}" ]]; then
    while IFS=' ' read -r sname sip; do
      [[ -z "${sname}" ]] && continue
      if ! echo "${labeled}" | grep -qw "${sname}" 2>/dev/null; then
        # Verify pod still exists and get current IP.
        local cur_ip
        cur_ip="$(ssh_s "${MASTER_TARGET}" \
          "kubectl get pod '${sname}' -n '${NET_NAMESPACE}' -o jsonpath='{.status.podIP}' 2>/dev/null" 2>/dev/null || true)"
        if [[ -n "${cur_ip}" ]]; then
          all+=$'\n'"${sname} ${cur_ip}"
        fi
      fi
    done < "${STEERED_FILE}"
  fi
  echo "${all}"
}

# Returns pods currently in endpoints (have the app label).
resolve_endpoint_pods() {
  ssh_s "${MASTER_TARGET}" \
    "kubectl get pods -n '${NET_NAMESPACE}' -l '${NET_TARGET_SELECTOR}' \
     -o custom-columns='NAME:.metadata.name,IP:.status.podIP' --no-headers" 2>/dev/null \
    | awk 'NF==2 {print $1, $2}'
}

# ---- Health probing ----

# Probe target_ip from probe_pod using grpc_health_probe inside the container.
# Returns 0 if healthy, 1 if faulty.
probe_health() {
  local probe_pod="$1" target_ip="$2"
  ssh_s "${MASTER_TARGET}" \
    "kubectl exec '${probe_pod}' -n '${NET_NAMESPACE}' -- \
     /bin/grpc_health_probe -addr='${target_ip}:${STEERING_SERVICE_PORT}' \
     -connect-timeout='${STEERING_PROBE_TIMEOUT}s' -rpc-timeout='${STEERING_PROBE_TIMEOUT}s' \
     2>/dev/null" >/dev/null 2>&1
}

# Find a working probe source pod.
# Strategy: self-probe is unreliable (localhost bypasses netem egress rules),
# so we verify candidates by cross-probing another pod.  We try pods from
# the END of the list first since net_delay_k8s.sh injects on the first N.
find_probe_source() {
  local all_pods="$1"
  local steered=""
  [[ -f "${STEERED_FILE}" ]] && steered="$(cat "${STEERED_FILE}" | awk '{print $1}')"

  # Build arrays (reversed order so we try last pods first).
  local -a names=() ips=()
  while IFS=' ' read -r n i; do
    [[ -z "${n}" ]] && continue
    names+=("${n}"); ips+=("${i}")
  done <<< "${all_pods}"

  local total=${#names[@]}

  # Try each candidate (reversed), verify by cross-probing another pod.
  for (( idx=total-1; idx>=0; idx-- )); do
    local candidate="${names[$idx]}" candidate_ip="${ips[$idx]}"
    # Skip if steered.
    echo "${steered}" | grep -qw "${candidate}" 2>/dev/null && continue

    # Self-probe: quick pre-filter.
    if ! probe_health "${candidate}" "${candidate_ip}"; then
      continue
    fi

    # Cross-probe: try to reach at least 1 other pod to confirm egress is clean.
    local cross_ok=0
    for (( j=total-1; j>=0; j-- )); do
      [[ "${j}" -eq "${idx}" ]] && continue
      if probe_health "${candidate}" "${ips[$j]}"; then
        cross_ok=1
        break
      fi
    done

    if [[ "${cross_ok}" -eq 1 ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  # Last resort: return any pod that self-probes (unreliable but better than nothing).
  for (( idx=total-1; idx>=0; idx-- )); do
    if probe_health "${names[$idx]}" "${ips[$idx]}"; then
      echo "${names[$idx]}"
      return 0
    fi
  done

  return 1
}

# ---- Actions ----

do_detect() {
  local all_pods
  all_pods="$(resolve_all_pods)"
  [[ -z "${all_pods}" ]] && { log "ERROR: no pods found"; return 1; }

  local pod_count
  pod_count="$(echo "${all_pods}" | grep -c '[a-z]' || echo 0)"
  log "Resolved ${pod_count} pods"

  local probe_source
  probe_source="$(find_probe_source "${all_pods}")" || {
    log "ERROR: no pod can serve as probe source (all unreachable)"
    return 1
  }
  log "Probe source: ${probe_source}"

  local healthy_list="" faulty_list=""
  local healthy_count=0 faulty_count=0

  while IFS=' ' read -r name ip; do
    [[ -z "${name}" ]] && continue
    if [[ "${name}" == "${probe_source}" ]]; then
      healthy_list+="${name} ${ip}\n"
      ((healthy_count++)) || true
      continue
    fi
    if probe_health "${probe_source}" "${ip}"; then
      healthy_list+="${name} ${ip}\n"
      ((healthy_count++)) || true
    else
      faulty_list+="${name} ${ip}\n"
      ((faulty_count++)) || true
    fi
  done <<< "${all_pods}"

  echo "========== Pod Health =========="
  echo "  Healthy (${healthy_count}):"
  [[ -n "${healthy_list}" ]] && printf "    %b" "${healthy_list}" | grep -v '^$' | while read -r n i; do echo "    ✓ ${n} (${i})"; done
  echo "  Faulty (${faulty_count}):"
  [[ -n "${faulty_list}" ]] && printf "    %b" "${faulty_list}" | grep -v '^$' | while read -r n i; do echo "    ✗ ${n} (${i})"; done

  # Write state for steer command.
  printf "%b" "${faulty_list}" | grep -v '^$' > /tmp/steering_faulty.txt 2>/dev/null || true
  printf "%b" "${healthy_list}" | grep -v '^$' > /tmp/steering_healthy.txt 2>/dev/null || true
}

## Wait until the number of Ready pods with the app label reaches the target.
wait_endpoints_ready() {
  local target="$1" timeout_sec="${2:-30}" elapsed=0
  while [[ "${elapsed}" -lt "${timeout_sec}" ]]; do
    local ready
    ready="$(ssh_s "${MASTER_TARGET}" \
      "kubectl get pods -n '${NET_NAMESPACE}' -l '${NET_TARGET_SELECTOR}' \
       --field-selector=status.phase=Running --no-headers 2>/dev/null \
       | grep -c '1/1'" 2>/dev/null || echo 0)"
    if [[ "${ready}" -ge "${target}" ]]; then
      return 0
    fi
    sleep 2
    ((elapsed+=2)) || true
  done
  log "  wait_endpoints_ready: timed out after ${timeout_sec}s (wanted ${target}, got ${ready:-?})"
  return 1
}

do_steer() {
  # Run detect first to get fresh state.
  do_detect

  local faulty_file="/tmp/steering_faulty.txt"
  local healthy_file="/tmp/steering_healthy.txt"

  [[ ! -s "${faulty_file}" ]] && { log "No faulty pods to steer."; return 0; }

  local healthy_count
  healthy_count="$(wc -l < "${healthy_file}" 2>/dev/null || echo 0)"
  local already_steered=""
  [[ -f "${STEERED_FILE}" ]] && already_steered="$(cat "${STEERED_FILE}")"

  # Count current endpoints (healthy + faulty that are still labeled).
  local current_endpoints
  current_endpoints="$(ssh_s "${MASTER_TARGET}" \
    "kubectl get pods -n '${NET_NAMESPACE}' -l '${NET_TARGET_SELECTOR}' --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 5)"

  while IFS=' ' read -r pod_name pod_ip; do
    [[ -z "${pod_name}" ]] && continue

    # Already steered?
    if echo "${already_steered}" | grep -qw "${pod_name}" 2>/dev/null; then
      log "  ${pod_name} already steered, skipping."
      continue
    fi

    # Safety: keep at least STEERING_MIN_HEALTHY healthy pods in endpoints.
    if [[ "${healthy_count}" -lt "${STEERING_MIN_HEALTHY}" ]]; then
      log "WARNING: only ${healthy_count} healthy pods (min=${STEERING_MIN_HEALTHY}), cannot steer ${pod_name}"
      break
    fi

    # ---- GRADUAL STEERING: one pod at a time ----

    # Step 1: Remove app label → K8s will create a replacement pod.
    log "STEER [1/3]: removing ${pod_name} (${pod_ip}) label..."
    ssh_s "${MASTER_TARGET}" "kubectl label pod '${pod_name}' -n '${NET_NAMESPACE}' app- 2>/dev/null" || true
    echo "${pod_name} ${pod_ip}" >> "${STEERED_FILE}"
    echo "$(date -Iseconds) STEER ${pod_name} ${pod_ip}" >> "${STEERING_LOG}"

    # Step 2: Wait for K8s to create replacement and become Ready.
    # After label removal, RS creates a new pod. Wait until endpoint count
    # is back to at least current_endpoints (meaning replacement is serving).
    log "STEER [2/3]: waiting for replacement pod to be Ready..."
    wait_endpoints_ready "${current_endpoints}" 30 || true

    # Step 3: NOW flush conntrack for this specific pod (safe — replacement is serving).
    for node in ${STEERING_CONNTRACK_NODES}; do
      ssh_s "$(target_host "${node}")" \
        "sudo /usr/sbin/conntrack -D -d '${pod_ip}' -p tcp --dport '${STEERING_SERVICE_PORT}' 2>/dev/null || true" >/dev/null 2>&1 || true
    done
    log "STEER [3/3]: flushed conntrack for ${pod_ip} — steering done for ${pod_name}"

  done < "${faulty_file}"

  log "Steering complete."
}

do_restore() {
  if [[ ! -s "${STEERED_FILE}" ]]; then
    log "No steered pods to restore."
    return 0
  fi

  log "Restoring all steered pods..."
  while IFS=' ' read -r pod_name pod_ip; do
    [[ -z "${pod_name}" ]] && continue
    ssh_s "${MASTER_TARGET}" \
      "kubectl label pod '${pod_name}' -n '${NET_NAMESPACE}' app=productcatalogservice --overwrite 2>/dev/null" || true
    log "  restored ${pod_name} (${pod_ip})"
    echo "$(date -Iseconds) RESTORE ${pod_name} ${pod_ip}" >> "${STEERING_LOG}"
  done < "${STEERED_FILE}"

  rm -f "${STEERED_FILE}"
  log "All pods restored."
}

do_status() {
  echo "========== Endpoint Membership =========="
  local ep_pods
  ep_pods="$(resolve_endpoint_pods)"
  local ep_count
  ep_count="$(echo "${ep_pods}" | grep -c '[a-z]' || echo 0)"
  echo "  In endpoints (${ep_count}):"
  echo "${ep_pods}" | while IFS=' ' read -r n i; do
    [[ -n "${n}" ]] && echo "    ${n} (${i})"
  done

  echo ""
  echo "========== Steered Away =========="
  if [[ -s "${STEERED_FILE}" ]]; then
    while IFS=' ' read -r n i; do
      echo "    ${n} (${i})"
    done < "${STEERED_FILE}"
  else
    echo "    (none)"
  fi

  echo ""
  echo "========== Conntrack (dport ${STEERING_SERVICE_PORT}) =========="
  for node in ${STEERING_CONNTRACK_NODES}; do
    local cnt
    cnt="$(ssh_s "$(target_host "${node}")" \
      "sudo /usr/sbin/conntrack -L -p tcp --dport '${STEERING_SERVICE_PORT}' 2>/dev/null | wc -l" 2>/dev/null || echo "?")"
    echo "  ${node}: ${cnt} entries"
  done
}

do_monitor() {
  log "Starting steering monitor (interval=${STEERING_INTERVAL}s, probe_timeout=${STEERING_PROBE_TIMEOUT}s, min_healthy=${STEERING_MIN_HEALTHY})"
  log "Log: ${STEERING_LOG}"

  # Clean state on start.
  rm -f /tmp/steering_faulty.txt /tmp/steering_healthy.txt

  while true; do
    # ---- Detect + steer faulty pods (resilient to transient errors) ----
    do_steer 2>&1 | while IFS= read -r line; do echo "$(ts) ${line}"; done || true

    # No auto-restore during monitor — steered pods stay out of endpoints
    # until explicitly restored (prevents flapping with probabilistic faults).

    sleep "${STEERING_INTERVAL}"
  done
}

# ---- Dispatch ----

case "${ACTION}" in
  detect)  do_detect ;;
  steer)   do_steer ;;
  restore) do_restore ;;
  status)  do_status ;;
  monitor) do_monitor ;;
  *)
    echo "Usage: $0 {detect|steer|restore|status|monitor}"
    echo "  Env: STEERING_INTERVAL  STEERING_PROBE_TIMEOUT  STEERING_MIN_HEALTHY"
    exit 1
    ;;
esac
