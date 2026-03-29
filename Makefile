.PHONY: help mimd rl heuristic train cadvisor inject inject-base inject-surge baseline observe status stop start-no-ctrl pack check-mimd net-delay-set net-delay-clear net-delay-run net-delay-status

help:
	@echo "TopFull quick commands:"
	@echo "  make mimd           - one-click MIMD start (auto ensure cAdvisor, then proxy + controller + metrics)"
	@echo "  make rl             - one-click RL start (auto ensure cAdvisor, then proxy + controller + metrics)"
	@echo "  make heuristic      - one-click heuristic start (proxy + controller + metrics)"
	@echo "  make train          - start online RL training (proxy + metrics + transfer_learning, no injection)"
	@echo "  make cadvisor       - ensure/redeploy cAdvisor on master and wait until ready"
	@echo "  make start          - start proxy + metrics only on master (no controller)"
	@echo "  make inject         - start normal load injection on loadgen"
	@echo "  make inject-base    - start Figure15 base load (optional: RATE=15 for 15%)"
	@echo "  make inject-surge   - start Figure15 surge load (optional: RATE=50, DURATION=2h)"
	@echo "  make baseline       - start loadgen only, no control (for baseline experiment)"
	@echo "  make observe        - show mitigation effect snapshot"
	@echo "  make status         - show overall runtime status"
	@echo "  make stop           - stop controller + loadgen (clear all injection)"
	@echo "  make pack           - zip logs (CSV) + PNG into one archive"
	@echo "  make check-mimd     - diagnose why MIMD/rate_config might not be updating"
	@echo ""
	@echo "Network delay injection:"
	@echo "  make net-delay-set     - inject network delay on target pods"
	@echo "  make net-delay-clear   - remove network delay from target pods"
	@echo "  make net-delay-run     - timed inject + release (uses NET_INJECT_AT_SEC / NET_RELEASE_AT_SEC)"
	@echo "  make net-delay-status  - show netem qdisc on target pods"

mimd:
	@./run_mimd_stack.sh

rl:
	@bash ./run_rl_stack.sh

heuristic:
	@bash ./run_heuristic_stack.sh

train:
	@bash ./run_rl_train.sh

cadvisor:
	@bash ./ensure_cadvisor.sh

start:
	@./start_stack_no_controller.sh

inject:
	@./start_injection_normal.sh

inject-base:
	@LOAD_RATE="$(or $(RATE),100)" ./start_injection_base.sh

inject-surge:
	@LOAD_RATE="$(or $(RATE),100)" INJECT_DURATION="$(DURATION)" ./start_injection_surge.sh

baseline:
	@./start_baseline.sh

observe:
	@./observe_mimd_effect.sh

status:
	@./check_topfull_status.sh

stop:
	@./stop_all.sh

pack:
	@./zip_topfull_artifacts.sh

check-mimd:
	@./check_mimd_running.sh

net-delay-set:
	@bash ./net_delay_k8s.sh set

net-delay-clear:
	@bash ./net_delay_k8s.sh clear

net-delay-run:
	@bash ./net_delay_k8s.sh run

net-delay-status:
	@bash ./net_delay_k8s.sh status
