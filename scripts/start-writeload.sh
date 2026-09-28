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

# Image with valkey-cli (preloaded into kind by 00-setup.sh).
CLIENT_IMAGE="${CLIENT_IMAGE:-valkey/valkey:9.0.0}"
CLIENT_POD="writeload"

# Create the dedicated client pod from a full manifest so the CA volume and its
# mount are defined at creation time (pod volumes can't be added after the
# fact). The pod idles with 'sleep infinity' so we can exec the client into it.
if ! kubectl -n "$NS" get pod "$CLIENT_POD" >/dev/null 2>&1; then
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
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: ca
          mountPath: /tls
          readOnly: true
  volumes:
    - name: ca
      configMap:
        name: valkey-demo-ca
YAML
fi
kubectl -n "$NS" wait --for=condition=Ready "pod/$CLIENT_POD" --timeout=60s

# Copy the client script into the dedicated pod.
kubectl -n "$NS" cp scripts/writeload.sh "$CLIENT_POD:/tmp/writeload.sh"

# Run it in the write pane. Uses the demo ACL user over TLS.
tmux send-keys -t "$SESSION:.1" \
  "kubectl -n $NS exec -it $CLIENT_POD -- env \
VK_HOST=$VK_HOST VK_PORT=6379 VK_TLS=1 VK_USER=demo VK_PASS=demoPassw0rd \
VK_CACERT=$VK_CACERT \
bash /tmp/writeload.sh" C-m
