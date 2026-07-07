#!/usr/bin/env bash
# watch-progress.sh — poll a running leanstart devnet's Prometheus during the
# settle window and log chain progress on an interval, so the sweep log shows
# live head/justified/finalized movement instead of going blank for minutes.
#
# Mirrors check-budgets.sh's Prometheus discovery + port-forward + promq path so
# the two stay consistent. Always exits 0 (it's an observer, not a gate): a
# stalled chain is data, not a script failure.
#
# Usage:
#   watch-progress.sh --context <ctx> --duration <secs> [options]
# Options:
#   --context <ctx>     kube context (required)
#   --namespace <ns>    devnet namespace (informational, default lean-devnet)
#   --metrics-ns <ns>   metrics namespace (default monitoring)
#   --duration <secs>   total time to watch (required)
#   --interval <secs>   seconds between samples (default 30)
#   --local-port <p>    local port-forward port (default 19091)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cloud/gke-lib.sh
source "$SCRIPT_DIR/gke-lib.sh"

CTX=""; DEVNET_NS="lean-devnet"; METRICS_NS="monitoring"
DURATION=""; INTERVAL=30; LOCAL_PORT="19091"
while [ $# -gt 0 ]; do
  case "$1" in
    --context)     CTX="$2"; shift 2 ;;
    --namespace)   DEVNET_NS="$2"; shift 2 ;;
    --metrics-ns)  METRICS_NS="$2"; shift 2 ;;
    --duration)    DURATION="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --local-port)  LOCAL_PORT="$2"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) gke::err "unknown arg: $1"; exit 1 ;;
  esac
done
[ -n "$CTX" ]      || { gke::err "--context is required"; exit 1; }
[ -n "$DURATION" ] || { gke::err "--duration is required"; exit 1; }
gke::require kubectl curl python3

# --- discover the Prometheus service (same logic as check-budgets.sh) ---------
PROM_SVC="$(kubectl --context "$CTX" -n "$METRICS_NS" get svc prometheus-operated \
  -o name 2>/dev/null || true)"
if [ -z "$PROM_SVC" ]; then
  PROM_SVC="$(kubectl --context "$CTX" -n "$METRICS_NS" get svc -o name 2>/dev/null \
    | grep -iE 'prometheus' \
    | grep -viE 'operator|alertmanager|grafana|node|kube-state|thanos' | head -1)"
fi
if [ -z "$PROM_SVC" ]; then
  # Non-fatal: just skip watching, let the caller's settle proceed.
  gke::log "watch-progress: no Prometheus service yet in '$METRICS_NS'; sleeping ${DURATION}s without polling"
  sleep "$DURATION"; exit 0
fi

# --- port-forward it ----------------------------------------------------------
PF_PID=""; PF_LOG="$(mktemp)"
pf_cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; rm -f "$PF_LOG"; }
trap pf_cleanup EXIT

kubectl --context "$CTX" -n "$METRICS_NS" port-forward \
  "$PROM_SVC" "$LOCAL_PORT:9090" >"$PF_LOG" 2>&1 &
PF_PID=$!
PROM="http://localhost:$LOCAL_PORT"
for _ in $(seq 1 60); do
  curl -fsS "$PROM/-/ready" >/dev/null 2>&1 && break
  sleep 1
done

# promq — instant query, prints the scalar value or "" on any error.
promq() {
  curl -fsSG "$PROM/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); r=d["data"]["result"]
    print(r[0]["value"][1] if r else "")
except Exception:
    print("")'
}
# Format a scalar: integer slots as ints, peers with one decimal, "·" if empty.
fmt() { [ -z "$1" ] && { printf '·'; return; }; printf '%.0f' "$1" 2>/dev/null || printf '%s' "$1"; }

gke::log "Settling ${DURATION}s — polling chain every ${INTERVAL}s (head/just/fin/safe/peers)"
START="$(date +%s)"; END=$((START + DURATION))
while :; do
  now="$(date +%s)"; elapsed=$((now - START))
  head="$(promq 'max(lean_head_slot)')"
  just="$(promq 'max(lean_latest_justified_slot)')"
  fin="$(promq 'max(lean_latest_finalized_slot)')"
  safe="$(promq 'max(lean_safe_target_slot)')"
  peers="$(promq 'avg(lean_connected_peers)')"
  peers_s="$([ -z "$peers" ] && printf '·' || printf '%.1f' "$peers" 2>/dev/null || printf '%s' "$peers")"
  printf '    [t+%4ss] head=%s  just=%s  fin=%s  safe=%s  peers=%s\n' \
    "$elapsed" "$(fmt "$head")" "$(fmt "$just")" "$(fmt "$fin")" "$(fmt "$safe")" "$peers_s"
  [ "$now" -ge "$END" ] && break
  remaining=$((END - now))
  sleep "$(( remaining < INTERVAL ? remaining : INTERVAL ))"
done

exit 0
