#!/usr/bin/env bash
set -euo pipefail

# Master node (node0) one-command setup.
# Usage on node0:
#   cd ~/TopFullExt
#   ./setup_master.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/setup.sh" master
