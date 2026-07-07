#!/usr/bin/env bash
# dump-devnet5-metrics.sh — one-shot: provision a tiny devnet on the colleague's
# devnet5 ream image, scrape the aggregator's raw /metrics, save the full metric
# catalog, and tear everything down. Used to learn devnet5's renamed metric
# names so check-budgets.sh can be wired to them (the devnet5 aggregation is a
# zkVM bytecode prover; the devnet4 leaf timer was renamed/removed).
#
# Usage: dump-devnet5-metrics.sh [out_dir]   (default ./results)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/cloud/gke-lib.sh
source "$SCRIPT_DIR/gke-lib.sh"

CREDENTIALS="${GKE_CREDENTIALS:-}"
IMG="${REAM_IMAGE_OVERRIDE:-snaiyer1/ream:latest-devnet5}"
NS="lean-devnet"
OUT_DIR="${1:-$REPO_ROOT/results}"
: "${GKE_CLUSTER:=leanstart-sweep}"
[ -n "$CREDENTIALS" ] || { gke::err "GKE_CREDENTIALS not set (need .env)"; exit 1; }

# leanstart binary
LEANSTART=""
for cand in "$REPO_ROOT/target/release/leanstart" "$REPO_ROOT/target/debug/leanstart"; do
  [ -x "$cand" ] && { LEANSTART="$cand"; break; }
done
[ -n "$LEANSTART" ] || { gke::err "leanstart binary not found (cargo build --release)"; exit 1; }

mkdir -p "$OUT_DIR"
CTX=""
cleanup() {
  trap - EXIT INT TERM
  [ -n "${CTX:-}" ] && pkill -9 -f "$CTX logs" 2>/dev/null
  [ -n "${PF:-}" ] && kill "$PF" 2>/dev/null
  if [ -n "${CTX:-}" ]; then
    kubectl --context "$CTX" delete pvc --all -A --wait=true --timeout=120s >/dev/null 2>&1 || true
  fi
  gke::cluster_down "$GKE_CLUSTER" || gke::err "teardown failed — check console! cluster=$GKE_CLUSTER"
  gke::cleanup
}
gke::auth "$CREDENTIALS"
trap cleanup EXIT INT TERM

if ! CTX="$(gke::ensure_cluster "$GKE_CLUSTER" 1 1)" || [ -z "$CTX" ]; then
  gke::err "provisioning failed"; exit 1
fi

gke::log "Deploying ream:3 / 1 subnet on $IMG"
GENESIS_OFFSET=90
if ! LS_IMAGE_REAM="$IMG" "$LEANSTART" run ream:3 \
    --subnets 1 --validators-per-pod 1 --aggregator-hosts agg0 \
    --genesis-offset "$GENESIS_OFFSET" --namespace "$NS" \
    --skip-kind --context "$CTX" >&2; then
  gke::err "deploy failed"; exit 1
fi

# Wait out genesis + a few slots so aggregation histograms/counters populate.
gke::log "Waiting for ream-0-0 ready + aggregation to run (~genesis + slots)..."
kubectl --context "$CTX" -n "$NS" wait --for=condition=ready pod/ream-0-0 --timeout=120s >&2 2>&1 || true
sleep $((GENESIS_OFFSET + 90))

# Scrape the aggregator's raw exposition straight off the pod (8080).
gke::log "Port-forwarding ream-0-0:8080 and scraping /metrics"
kubectl --context "$CTX" -n "$NS" port-forward pod/ream-0-0 18080:8080 >/dev/null 2>&1 &
PF=$!; sleep 6
RAW="$OUT_DIR/devnet5-metrics.raw"
curl -s --max-time 20 http://localhost:18080/metrics > "$RAW" || gke::err "curl /metrics failed"
kill "$PF" 2>/dev/null; PF=""

if [ ! -s "$RAW" ]; then gke::err "empty /metrics — scrape failed"; exit 1; fi

# Metric-name catalog + the aggregation/timing-relevant subset with sample values.
NAMES="$OUT_DIR/devnet5-metric-names.txt"
grep -E '^[a-zA-Z_][a-zA-Z0-9_]*(\{| )' "$RAW" | sed -E 's/[ {].*$//' | sort -u > "$NAMES"
gke::log "Saved $(wc -l < "$NAMES" | tr -d ' ') metric names -> $NAMES (raw: $RAW)"
gke::log "Aggregation / timing / committee metrics (name = sample):"
grep -iE '^(lean_)?[a-z0-9_]*(aggreg|prover|verif|committee|attestation|pq_sig|finaliz|slot)[a-z0-9_]*' "$RAW" \
  | grep -vE '_bucket\{' | grep -viE '^# ' | sort -u | head -60 >&2
gke::log "Done — review $NAMES then wire check-budgets.sh to the devnet5 names."
