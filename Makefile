# ValkeyConf 2026 operator demo
#
# Typical flow:
#   make setup      # off-camera: kind + operator + TLS/ACL secrets + image preload
#   make layout     # build the tmux panes (rehearse the look)
#   make record     # run VHS -> out/demo.mp4 + out/demo.gif
#   make teardown   # delete the kind cluster

CLUSTER ?= valkey-demo
NS       ?= demo
SESSION  ?= demo

.PHONY: setup layout record reset deploy writeload teardown clean check

check:  ## verify required tools are installed
	@missing=""; \
	for t in kind kubectl helm vhs tmux ffmpeg ttyd watch docker openssl; do \
		command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "MISSING:$$missing"; \
		echo "see the README 'Prerequisites' section for install instructions"; \
		exit 1; \
	fi; \
	echo "all tools present"

setup:  ## off-camera: create cluster, install operator, create secrets, preload images
	CLUSTER=$(CLUSTER) NS=$(NS) ./scripts/00-setup.sh

layout: ## build the tmux 3-pane layout (attach with: tmux attach -t demo)
	SESSION=$(SESSION) NS=$(NS) ./scripts/tmux-layout.sh

deploy: ## apply the demo ValkeyCluster (normally done on-camera by the tape)
	kubectl -n $(NS) apply -f manifests/valkeycluster.yaml

writeload: ## start the write-load counter in the tmux write pane
	SESSION=$(SESSION) NS=$(NS) ./scripts/start-writeload.sh

record: reset ## run VHS to produce out/demo.mp4 (resets the demo state first)
	mkdir -p out
	vhs demo.tape

reset: ## delete the ValkeyCluster and write-load pod so the next record is fresh
	-kubectl -n $(NS) delete valkeycluster my-cluster --ignore-not-found
	-kubectl -n $(NS) delete pod writeload --ignore-not-found
	@echo "waiting for cluster pods to clear..."
	-kubectl -n $(NS) wait --for=delete pod \
		-l app.kubernetes.io/name=valkey --timeout=90s 2>/dev/null
	-tmux kill-session -t $(SESSION) 2>/dev/null

teardown: ## delete the kind cluster and the tmux session
	-tmux kill-session -t $(SESSION) 2>/dev/null
	CLUSTER=$(CLUSTER) ./scripts/teardown.sh

clean: ## remove rendered output
	rm -rf out
