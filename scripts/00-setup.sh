#!/usr/bin/env bash
#
# 00-setup.sh - one-time, OFF-CAMERA setup. Do NOT record this; it's slow
# (image pulls, cluster bootstrap). Run it, wait for Ready, then record demo.tape.
#
# Creates: a kind cluster, the operator, a demo namespace, the TLS Secret and
# the ACL password Secret. Pre-loads two Valkey images so the upgrade step is
# instant on camera.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER="${CLUSTER:-valkey-demo}"
NS="${NS:-demo}"
VK_FROM_IMG="${VK_FROM_IMG:-valkey/valkey:9.0.0}"
VK_TO_IMG="${VK_TO_IMG:-valkey/valkey:9.1.0}"

echo "==> kind cluster: $CLUSTER"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"

echo "==> pre-load Valkey images (so the on-camera upgrade is instant)"
for img in "$VK_FROM_IMG" "$VK_TO_IMG"; do
  docker pull "$img" >/dev/null
  kind load docker-image "$img" --name "$CLUSTER"
done

echo "==> build and load the write-load client image (off camera, so the demo's
    start-writeload is instant)"
WRITELOAD_IMAGE="${WRITELOAD_IMAGE:-writeload-client:demo}"
docker build -t "$WRITELOAD_IMAGE" ./writeload-client
kind load docker-image "$WRITELOAD_IMAGE" --name "$CLUSTER"

echo "==> install the operator (Helm)"
helm repo add valkey https://valkey.io/valkey-helm 2>/dev/null || true
helm repo update >/dev/null
helm upgrade --install valkey-operator valkey/valkey-operator \
  -n valkey-operator-system --create-namespace --wait

echo "==> namespace: $NS"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "==> TLS Secret (self-signed, demo only)"
tmp="$(mktemp -d)"
# The operator dials nodes by their in-cluster FQDNs and verifies the server
# cert against them, e.g. valkey-<cluster>.<ns>.svc.cluster.local and per-pod
# names valkey-<cluster>-N-M-0.valkey-<cluster>.<ns>.svc.cluster.local. DNS
# wildcards match a single label, so *.<ns>.svc does NOT cover a
# .svc.cluster.local name; the SAN list must spell out each level. SVC is the
# Service name the operator creates: "valkey-<cluster>".
SVC="valkey-my-cluster"
SANS="DNS:localhost"
SANS="$SANS,DNS:$SVC,DNS:$SVC.${NS},DNS:$SVC.${NS}.svc,DNS:$SVC.${NS}.svc.cluster.local"
# Per-pod FQDNs under the headless Service (any pod ordinal).
SANS="$SANS,DNS:*.$SVC,DNS:*.$SVC.${NS}.svc,DNS:*.$SVC.${NS}.svc.cluster.local"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/tls.key" -out "$tmp/tls.crt" \
  -subj "/CN=$SVC" \
  -addext "subjectAltName=$SANS" >/dev/null 2>&1
# The cert is self-signed, so it is its own CA. Valkey (and the metrics exporter)
# are configured with a CA path, so the Secret must carry ca.crt alongside
# tls.crt/tls.key; a kubernetes.io/tls Secret holds only the latter two. Build a
# generic Secret with all three keys so the CA file exists at the mount path.
kubectl -n "$NS" create secret generic valkey-server-tls \
  --from-file=tls.crt="$tmp/tls.crt" \
  --from-file=tls.key="$tmp/tls.key" \
  --from-file=ca.crt="$tmp/tls.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
# Keep the CA around for the write-load client.
kubectl -n "$NS" create configmap valkey-demo-ca \
  --from-file=ca.crt="$tmp/tls.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$tmp"

echo "==> ACL password Secret"
kubectl -n "$NS" create secret generic valkey-demo-users \
  --from-literal=demopw="demoPassw0rd" \
  --from-literal=defaultpw="defaultPassw0rd" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Setup complete. Set the starting image, then you're ready to record:"
echo "  kubectl -n $NS apply -f manifests/valkeycluster.yaml   # (image set by demo.tape)"
echo "Record with:  vhs demo.tape"
