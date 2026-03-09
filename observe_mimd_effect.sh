#!/usr/bin/env bash
set -euo pipefail

# Observe mitigation effect snapshot:
# - controller log tail
# - metrics total.csv tail
# - proxy rate_config recent updates

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

ssh "${MASTER_TARGET}" bash -s -- "${PROJECT_NAME}" <<'REMOTE'
set -euo pipefail
project_name="${1:-TopFullExt}"
src_dir="${HOME}/${project_name}/TopFull_master/online_boutique_scripts/src"
proxy_dir="$(
python3 - <<'PY'
import json
import os
from pathlib import Path
p = Path(os.path.expanduser("~/TopFullExt/TopFull_master/online_boutique_scripts/src/global_config.json"))
if p.exists():
    cfg = json.loads(p.read_text())
    d = cfg.get("proxy_dir", "")
    d = os.path.expandvars(os.path.expanduser(d))
    print(d)
PY
)"

echo "========== controller log (tail -n 80) =========="
tail -n 80 /tmp/topfull-controller.log 2>/dev/null || echo "controller log not found"

echo
echo "========== metrics total.csv (tail -n 20) =========="
tail -n 20 "${src_dir}/logs/total.csv" 2>/dev/null || echo "metrics csv not found"

echo
echo "========== proxy rate_config (latest 20) =========="
if [[ -n "${proxy_dir}" && -d "${proxy_dir}" ]]; then
  ls -lt "${proxy_dir}" | sed -n '1,20p'
else
  ls -lt "${src_dir}/proxy/rate_config" 2>/dev/null | sed -n '1,20p' || echo "rate_config dir not found"
fi
REMOTE

