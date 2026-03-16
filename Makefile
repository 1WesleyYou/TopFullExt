.PHONY: help mimd rl train cadvisor inject inject-base inject-surge baseline observe status stop start-no-ctrl pack check-mimd

help:
	@echo "TopFull quick commands:"
	@echo "  make mimd           - one-click MIMD start (auto ensure cAdvisor, then proxy + controller + metrics)"
	@echo "  make rl             - one-click RL start (auto ensure cAdvisor, then proxy + controller + metrics)"
	@echo "  make train          - start online RL training (proxy + metrics + transfer_learning, no injection)"
	@echo "  make cadvisor       - ensure/redeploy cAdvisor on master and wait until ready"
	@echo "  make start          - start proxy + metrics only on master (no controller)"
	@echo "  make inject         - start normal load injection on loadgen"
	@echo "  make inject-base    - start Figure15 base load"
	@echo "  make inject-surge   - start Figure15 surge load"
	@echo "  make baseline       - start loadgen only, no control (for baseline experiment)"
	@echo "  make observe        - show mitigation effect snapshot"
	@echo "  make status         - show overall runtime status"
	@echo "  make stop           - stop controller + loadgen (clear all injection)"
	@echo "  make pack           - zip logs (CSV) + PNG into one archive"
	@echo "  make check-mimd     - diagnose why MIMD/rate_config might not be updating"

mimd:
	@./run_mimd_stack.sh

rl:
	@bash ./run_rl_stack.sh

train:
	@bash ./run_rl_train.sh

cadvisor:
	@bash ./ensure_cadvisor.sh

start:
	@./start_stack_no_controller.sh

inject:
	@./start_injection_normal.sh

inject-base:
	@./start_injection_base.sh

inject-surge:
	@./start_injection_surge.sh

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
