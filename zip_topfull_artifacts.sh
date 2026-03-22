#!/usr/bin/env bash
set -euo pipefail

# One-click bundle for TopFull experiment artifacts:
# - CSV files under logs dir
# - Generated PNG files under repo root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

resolve_default_logs_dir() {
  local candidates=()
  local c

  if [[ -n "${RECORD_PATH:-}" ]]; then
    candidates+=("${RECORD_PATH%/}")
  fi
  if [[ -n "${PROJECT_ROOT:-}" ]]; then
    candidates+=("${PROJECT_ROOT}/TopFull_master/online_boutique_scripts/src/logs")
  fi
  candidates+=("${HOME}/${PROJECT_NAME:-TopFullExt}/TopFull_master/online_boutique_scripts/src/logs")
  candidates+=("${SCRIPT_DIR}/TopFull_master/online_boutique_scripts/src/logs")

  for c in "${candidates[@]}"; do
    if [[ -d "${c}" ]]; then
      printf "%s" "${c}"
      return 0
    fi
  done

  # Fallback to first candidate for clearer error reporting later.
  printf "%s" "${candidates[0]}"
}

DEFAULT_LOGS_DIR="$(resolve_default_logs_dir)"
LOGS_DIR="${TOPFULL_LOGS_DIR:-${DEFAULT_LOGS_DIR}}"

usage() {
  cat <<'EOF'
Usage:
  bash zip_topfull_artifacts.sh [output_zip_name] [--logs-dir <path>]

Examples:
  bash zip_topfull_artifacts.sh
  bash zip_topfull_artifacts.sh run1_bundle.zip
  bash zip_topfull_artifacts.sh run1_bundle --logs-dir ~/TopFullExt/TopFull_master/online_boutique_scripts/src/logs

Notes:
  - If output name has no .zip suffix, .zip will be appended automatically.
  - You can also set logs directory by env var:
      TOPFULL_LOGS_DIR=/path/to/logs bash zip_topfull_artifacts.sh
EOF
}

OUTPUT_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --logs-dir)
      shift
      if [[ $# -eq 0 ]]; then
        echo "error: --logs-dir requires a path" >&2
        exit 1
      fi
      LOGS_DIR="$(eval echo "$1")"
      shift
      ;;
    *)
      if [[ -z "${OUTPUT_NAME}" ]]; then
        OUTPUT_NAME="$1"
        shift
      else
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if ! command -v zip >/dev/null 2>&1; then
  echo "error: 'zip' command not found. Install it first (e.g. sudo apt-get install zip)." >&2
  exit 1
fi

if [[ -z "${OUTPUT_NAME}" ]]; then
  OUTPUT_NAME="topfull_artifacts_$(date +%Y%m%d_%H%M%S).zip"
fi
if [[ "${OUTPUT_NAME}" != *.zip ]]; then
  OUTPUT_NAME="${OUTPUT_NAME}.zip"
fi

if [[ "${OUTPUT_NAME}" = /* ]]; then
  OUTPUT_PATH="${OUTPUT_NAME}"
else
  OUTPUT_PATH="${SCRIPT_DIR}/${OUTPUT_NAME}"
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"

if [[ ! -d "${LOGS_DIR}" ]]; then
  echo "error: logs directory not found: ${LOGS_DIR}" >&2
  exit 1
fi

shopt -s nullglob
csv_files=("${LOGS_DIR}"/*.csv)
png_files=("${SCRIPT_DIR}"/*.png)
shopt -u nullglob

if [[ ${#csv_files[@]} -eq 0 && ${#png_files[@]} -eq 0 ]]; then
  echo "error: no CSV/PNG files found to archive." >&2
  echo "checked logs dir: ${LOGS_DIR}" >&2
  echo "checked png dir:  ${SCRIPT_DIR}" >&2
  exit 1
fi

tmp_filelist="$(mktemp)"
trap 'rm -f "${tmp_filelist}"' EXIT

for f in "${csv_files[@]}"; do
  if [[ "${f}" = "${SCRIPT_DIR}"/* ]]; then
    printf '%s\n' "${f#${SCRIPT_DIR}/}" >> "${tmp_filelist}"
  else
    printf '%s\n' "${f}" >> "${tmp_filelist}"
  fi
done
for f in "${png_files[@]}"; do
  printf '%s\n' "${f#${SCRIPT_DIR}/}" >> "${tmp_filelist}"
done

(
  cd "${SCRIPT_DIR}"
  # -@ reads file list from stdin; keep relative paths for readability.
  zip -q -r "${OUTPUT_PATH}" -@ < "${tmp_filelist}"
)

echo "saved: ${OUTPUT_PATH}"
echo "csv_count: ${#csv_files[@]}"
echo "png_count: ${#png_files[@]}"
