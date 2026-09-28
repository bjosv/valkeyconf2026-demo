#!/usr/bin/env bash
#
# writeload.sh - continuously write to the cluster and count acked vs lost writes.
# The "LOST: 0" line staying at zero through upgrade/scale/failover is the
# money shot of the demo.
#
# Runs from INSIDE a Valkey pod (so TLS + in-cluster DNS just work), driven by
# scripts/lib.sh::writeload_pane. It uses valkey-cli -c to follow MOVED
# redirects, so a slot moving during failover/rebalance is NOT counted as a loss.
#
# Env (all optional, sane defaults):
#   VK_HOST, VK_PORT, VK_USER, VK_PASS, VK_TLS (1/0), VK_CACERT, VK_SLEEP
set -uo pipefail

host="${VK_HOST:-127.0.0.1}"
port="${VK_PORT:-6379}"
user="${VK_USER:-demo}"
pass="${VK_PASS:-}"
sleep_s="${VK_SLEEP:-0.05}"

tls_args=()
if [ "${VK_TLS:-1}" = "1" ]; then
  tls_args+=(--tls)
  [ -n "${VK_CACERT:-}" ] && tls_args+=(--cacert "${VK_CACERT}")
  tls_args+=(--insecure)   # demo certs; skip hostname verification
fi

auth_args=()
[ -n "$user" ] && auth_args+=(--user "$user")
[ -n "$pass" ] && auth_args+=(--pass "$pass")

i=0; ok=0; lost=0
trap 'echo; echo "final: writes=$i acked=$ok LOST=$lost"; exit 0' INT TERM

printf 'write-load against %s:%s as user "%s"\n\n' "$host" "$port" "$user"
while true; do
  i=$((i+1))
  if valkey-cli -h "$host" -p "$port" "${tls_args[@]}" "${auth_args[@]}" \
       -c set "demo:key:$i" "$i" >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    lost=$((lost+1))
  fi
  printf '\rwrites: %-8d  acked: %-8d  LOST: %-6d' "$i" "$ok" "$lost"
  sleep "$sleep_s"
done
