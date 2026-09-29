#!/usr/bin/env bash
#
# start-writeload.sh - launch the write-load counter in the tmux write pane.
#
# Runs the client in a DEDICATED pod (not a cluster member). The demo rolls
# every cluster pod during upgrade/scale/failover; a client exec'd into a
# cluster pod is SIGKILLed (exit 137) the moment that pod is rolled. A separate
# pod survives all of that, which is what lets LOST stay at 0 on camera.
#
# TLS: mounts the demo CA from the valkey-demo-ca ConfigMap (created by
# 00-setup.sh). Connects to the headless Service over TLS.
set -euo pipefail
cd "$(dirname "$0")/.."

SESSION="${SESSION:-demo}"
NS="${NS:-demo}"
CLUSTER_NAME="${CLUSTER_NAME:-my-cluster}"

# CA path inside the dedicated client pod. The pod mounts the valkey-demo-ca
# ConfigMap (key ca.crt) at /tls. Override if you change the mount below.
VK_CACERT="${VK_CACERT:-/tls/ca.crt}"

# The operator names the Service "valkey-<cluster>", not "<cluster>". Look it up
# so the client connects to a name that actually resolves in-cluster; fall back
# to the conventional name if the lookup finds nothing.
VK_HOST="$(kubectl -n "$NS" get svc -o jsonpath='{.items[?(@.spec.ports[0].port==6379)].metadata.name}' 2>/dev/null | awk '{print $1}')"
VK_HOST="${VK_HOST:-valkey-$CLUSTER_NAME}"

# Client image, built and loaded into kind by 00-setup.sh. If you change the
# client code, rebuild and reload it before running this:
#   docker build -t writeload-client:demo ./writeload-client
#   kind load docker-image writeload-client:demo --name valkey-demo
CLIENT_IMAGE="${WRITELOAD_IMAGE:-writeload-client:demo}"
CLIENT_POD="writeload"

# Create the dedicated client pod. The client holds a persistent, cluster-aware
# connection, so failover and slot migration are handled by the library, not
# counted as lost writes. Connection settings live in the pod environment; the
# password comes from the ACL Secret via secretKeyRef, so no secret is ever
# typed on camera. The CA is mounted at /tls from the valkey-demo-ca ConfigMap.
# Recreate the pod each time so a code change (new image tag) always takes
# effect; a leftover pod from a previous run would otherwise keep the old image.
kubectl -n "$NS" delete pod "$CLIENT_POD" --ignore-not-found >/dev/null 2>&1
kubectl -n "$NS" wait --for=delete "pod/$CLIENT_POD" --timeout=30s >/dev/null 2>&1 || true
kubectl -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $CLIENT_POD
  labels:
    app: writeload
spec:
  restartPolicy: Never
  containers:
    - name: client
      image: $CLIENT_IMAGE
      imagePullPolicy: IfNotPresent
      # tty + stdin so the client's carriage-return-updated counter renders when
      # we 'kubectl attach' to it from the write pane.
      tty: true
      stdin: true
      env:
        - name: VK_HOST
          value: "$VK_HOST"
        - name: VK_PORT
          value: "6379"
        - name: VK_TLS
          value: "1"
        - name: VK_USER
          value: "demo"
        - name: VK_CACERT
          value: "$VK_CACERT"
        - name: VK_RPS
          value: "20"
        - name: VK_PASS
          valueFrom:
            secretKeyRef:
              name: valkey-demo-users
              key: demopw
      volumeMounts:
        - name: ca
          mountPath: /tls
          readOnly: true
  volumes:
    - name: ca
      configMap:
        name: valkey-demo-ca
YAML
kubectl -n "$NS" wait --for=condition=Ready "pod/$CLIENT_POD" --timeout=60s

# Find the write-load pane by the title tmux-layout.sh set on it, so we don't
# depend on a positional index. Fall back to pane .1 if no titled pane is found.
WRITE_PANE="$(tmux list-panes -t "$SESSION" -F '#{pane_id} #{pane_title}' 2>/dev/null \
  | awk '$2=="writeload"{print $1; exit}')"
WRITE_PANE="${WRITE_PANE:-$SESSION:.1}"

# Show the live counter in the write pane by attaching to the running client.
# A TTY renders the carriage-return-updated single line (the pod sets
# tty/stdin). Clear first so the pane starts clean; --quiet suppresses kubectl's
# attach preamble ("If you don't see a command prompt...", audit notices).
tmux send-keys -t "$WRITE_PANE" \
  "clear; kubectl -n $NS attach -it --quiet $CLIENT_POD" C-m
