#!/usr/bin/env bash
#
# show-topology.sh - print a clean per-shard slot map for the demo cluster.
#
# Takes no arguments so it reads well on camera (./scripts/show-topology.sh).
# Connects over TLS as the demo ACL user (password read from the Secret) and
# formats CLUSTER NODES into one line per primary, pod name then owned slots:
#
#   valkey-my-cluster-0-0-0   1034-1365 5462-6095 11392-11791 12288-16383
#   valkey-my-cluster-1-1-0   0-868 1366-5461 10992-11391 12192-12287
#   valkey-my-cluster-2-1-0   869-1033 6096-10991 11792-12191
#
# CLUSTER NODES is one flat line per node, so no nested-array parsing is needed.
# A primary (master) line ends with its owned slot range(s); replicas have none.
set -euo pipefail
cd "$(dirname "$0")/.."

NS="${NS:-demo}"
CLUSTER_NAME="${CLUSTER_NAME:-my-cluster}"
VK_USER="${VK_USER:-demo}"
VK_CACERT="${VK_CACERT:-/tls/ca.crt}"

# The operator names the Service "valkey-<cluster>". Look it up; fall back to the
# conventional name.
VK_HOST="$(kubectl -n "$NS" get svc -o jsonpath='{.items[?(@.spec.ports[0].port==6379)].metadata.name}' 2>/dev/null | awk '{print $1}')"
VK_HOST="${VK_HOST:-valkey-$CLUSTER_NAME}"

# A cluster pod to run valkey-cli from (any member; the CA is mounted at /tls).
POD="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=valkey \
        -o jsonpath='{.items[0].metadata.name}')"

# Demo password from the Secret. This script's command line is never recorded
# (only "./scripts/show-topology.sh" appears on camera), so --pass is fine here.
PASS="$(kubectl -n "$NS" get secret valkey-demo-users \
          -o jsonpath='{.data.demopw}' | base64 --decode)"

# Each master line looks like:
#   <id> <ip:port@cbus>,<pod-fqdn> master - 0 0 <epoch> connected 0-868 1366-5461 ...
# The pod FQDN follows the comma in field 2; a master owns one or more slot
# ranges from field 9 onward (the operator may assign non-contiguous ranges).
# Print one line per primary: "<pod-name>  <all its slot ranges>".
# Header row, then the sorted body (printed separately so sort doesn't reorder
# the header).
printf '%-24s %s\n' "NAME" "SLOT RANGES"
kubectl -n "$NS" exec -i "$POD" -c server -- \
  valkey-cli -h "$VK_HOST" -p 6379 \
    --tls --cacert "$VK_CACERT" --insecure \
    --user "$VK_USER" --pass "$PASS" --no-auth-warning \
    cluster nodes \
  | awk '
      $3 ~ /master/ {
        # Pod name: field 2 is "ip:port@cbus,pod-fqdn"; take after comma, before first dot.
        n = split($2, a, ",")
        host = a[n]
        sub(/\..*/, "", host)
        # Slot ranges are fields 9..NF (after "connected").
        ranges = ""
        for (i = 9; i <= NF; i++) ranges = ranges (ranges == "" ? "" : " ") $i
        printf "%-24s %s\n", host, ranges
      }
    ' \
  | sort

