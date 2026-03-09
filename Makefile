.PHONY: help mimd inject inject-base inject-surge observe status

help:
	@echo "TopFull quick commands:"
	@echo "  make mimd         - start/restart MIMD stack on master"
	@echo "  make inject       - start normal load injection on loadgen"
	@echo "  make inject-base  - start Figure15 base load"
	@echo "  make inject-surge - start Figure15 surge load"
	@echo "  make observe      - show mitigation effect snapshot"
	@echo "  make status       - show overall runtime status"

mimd:
	@./run_mimd_stack.sh

inject:
	@./start_injection_normal.sh

inject-base:
	@./start_injection_base.sh

inject-surge:
	@./start_injection_surge.sh

observe:
	@./observe_mimd_effect.sh

status:
	@./check_topfull_status.sh
