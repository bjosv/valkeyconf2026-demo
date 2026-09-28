#!/usr/bin/env bash
#
# teardown.sh - delete the kind cluster used for the demo.
set -euo pipefail
CLUSTER="${CLUSTER:-valkey-demo}"
kind delete cluster --name "$CLUSTER"
