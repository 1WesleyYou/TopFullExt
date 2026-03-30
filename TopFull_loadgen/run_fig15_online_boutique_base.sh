#!/bin/bash
set -euo pipefail

BASE_GETPRODUCT=900
BASE_POSTCHECKOUT=30
BASE_CART=1000
SCALE="${LOAD_RATE:-100}"

if ! [[ "${SCALE}" =~ ^[0-9]+$ ]] || (( SCALE <= 0 )); then
  echo "Invalid LOAD_RATE=${SCALE}. Expected positive integer percentage, e.g. 10/15/100."
  exit 1
fi

scale_with_floor() {
  local base="$1"
  local scaled=$(( base * SCALE / 100 ))
  if (( scaled < 1 )); then
    scaled=1
  fi
  echo "${scaled}"
}

GETPRODUCT="$(scale_with_floor "${BASE_GETPRODUCT}")"
POSTCHECKOUT="$(scale_with_floor "${BASE_POSTCHECKOUT}")"
CART="$(scale_with_floor "${BASE_CART}")"
POSTCHECKOUT_R="$(scale_with_floor 2)"
GETPRODUCT_R="$(scale_with_floor 54)"
CART_R="$(scale_with_floor 60)"

tmux kill-session -t session4 2>/dev/null || true
tmux new-session -d -s session4


tmux new-window -d -t session4 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 -u $POSTCHECKOUT -r $POSTCHECKOUT_R --headless  --tags postcheckout < ports/8928"



tmux kill-session -t session5 2>/dev/null || true
tmux new-session -d -s session5


tmux new-window -d -t session5 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 -u $GETPRODUCT -r $GETPRODUCT_R --headless  --tags getproduct < ports/8929"



tmux kill-session -t session6 2>/dev/null || true
tmux new-session -d -s session6


tmux new-window -d -t session6 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 -u $CART -r $CART_R --headless  --tags getcart postcart emptycart < ports/8930"
