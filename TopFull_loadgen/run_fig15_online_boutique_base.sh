#!/bin/bash
GETPRODUCT=540
POSTCHECKOUT=18
GETCART=5000
POSTCART=2600
CART=600
RATE=10

tmux kill-session -t session4
tmux new-session -d -s session4


tmux new-window -d -t session4 "locust -f locust_online_boutique.py --host=http://10.8.0.4:30440 -u $POSTCHECKOUT -r 2 --headless  --tags postcheckout < ports/8928"



tmux kill-session -t session5
tmux new-session -d -s session5


tmux new-window -d -t session5 "locust -f locust_online_boutique.py --host=http://10.8.0.4:30440 -u $GETPRODUCT -r 54 --headless  --tags getproduct < ports/8929"



tmux kill-session -t session6
tmux new-session -d -s session6


tmux new-window -d -t session6 "locust -f locust_online_boutique.py --host=http://10.8.0.4:30440 -u $CART -r 60 --headless  --tags getcart postcart emptycart < ports/8930"
