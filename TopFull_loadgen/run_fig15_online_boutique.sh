#!/bin/bash
set -euo pipefail

BASE_GETPRODUCT=3660
BASE_POSTCHECKOUT=222
BASE_CART=5400
RATE=54
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

tmux kill-session -t session2 2>/dev/null || true
tmux new-session -d -s session2


tmux new-window -d -t session2 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 --tags postcheckout --master-bind-port=8881  --master --expect-workers=10 --headless -u $POSTCHECKOUT -r $(( (POSTCHECKOUT / RATE) > 0 ? (POSTCHECKOUT / RATE) : 1 )) -t 120s  < ports/8886"
for i in $(seq 1 10)
do
    tmux new-window -d -t session2 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 --tags postcheckout --worker --master-port=8881  --master-host=127.0.0.1 < ports/$((i+8907))"
done



tmux kill-session -t session1 2>/dev/null || true
tmux new-session -d -s session1


tmux new-window -d -t session1 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 --tags getproduct --master-bind-port=8882  --master --expect-workers=20 --headless -u $GETPRODUCT -r $((GETPRODUCT / RATE)) -t 120s  < ports/8887"
for i in $(seq 1 20)
do
    tmux new-window -d -t session1 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 --tags getproduct --worker --master-port=8882 --master-host=127.0.0.1 < ports/$((i+8887))"
done



tmux kill-session -t session3 2>/dev/null || true
tmux new-session -d -s session3


tmux new-window -d -t session3 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 --master-bind-port=8883 --tags getcart postcart emptycart --master --expect-workers=10 --headless -u $((CART+0)) -r $((CART / RATE)) -t 120s < ports/8885"
for i in $(seq 1 10)
do
    tmux new-window -d -t session3 "locust -f locust_online_boutique.py --host=http://10.10.1.1:30440 --master-port=8883 --tags getcart postcart emptycart --worker --master-host=127.0.0.1 < ports/$((i+8917))"
done
