#!/usr/bin/env bash
# gke-sweep.sh — run one topology on a fresh ephemeral GKE cluster and report
# whether it meets the aggregation-topology budgets.
#
# Flow (all in one process, fully scoped, cluster torn down on exit):
#   1. provision GKE: workers pool + one dedicated node per subnet aggregator
#   2. leanstart run <clients> --subnets N --aggregator-hosts agg0..aggN-1
#      --skip-kind --context <ctx>   (installs kube-prometheus-stack)
#   3. settle for --settle (chain produces/finalizes blocks, histograms warm)
#   4. check-budgets.sh -> PASS/FAIL vs leaf/recursion/finalization budgets
#   5. delete the cluster (EXIT trap; runs even on Ctrl-C / failure)
#
# To sweep multiple topologies, invoke this once per topology (each gets a
# clean cluster — matches the chosen ephemeral lifecycle) and point them all at
# the same --report CSV.
#
# Usage:
#   gke-sweep.sh --credentials <key.json> --clients "ream:5" --subnets 2 [opts]
#
# Options:
#   --credentials <path>     GCP SA key JSON (required)
#   --clients "<spec...>"    leanstart client spec(s), e.g. "ream:5" or
#                            "ream:3 zeam:2" (required)
#   --subnets <N>            number of subnets (required)
#   --validators-per-pod <V> default 1
#   --settle <dur>           soak time before measuring (default 600 = 10m)
#   --genesis-offset <secs>  default 180 (GKE image pulls need headroom)
#   --results-dir <dir>      where per-run <run_id>.json + runs.csv land (./results)
#   --namespace <ns>         devnet namespace (default lean-devnet)
#   --keep                   don't tear down the cluster (debugging)
#   --on-demand              on-demand nodes instead of Spot
#   --leanstart <path>       leanstart binary (default: autodetect)
#   machine/zone/cluster/project flags as in gke-up.sh
#   budget flags forwarded to check-budgets.sh:
#     --leaf-budget --recursion-budget --final-slots --window

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/cloud/gke-lib.sh
source "$SCRIPT_DIR/gke-lib.sh"

CREDENTIALS="${GKE_CREDENTIALS:-}"; CLIENTS=""; SUBNETS=""; VPP=1
SETTLE=600; GENESIS_OFFSET=180; RESULTS_DIR="./results"; DEVNET_NS="lean-devnet"
KEEP=0; SPOT=1; LEANSTART=""; REAM_IMAGE_OVERRIDE=""
: "${GKE_CLUSTER:=leanstart-sweep}"
# budget passthrough (empty => check-budgets defaults)
LEAF_BUDGET=""; REC_BUDGET=""; FINAL_SLOTS=""; WINDOW=""

while [ $# -gt 0 ]; do
  case "$1" in
    --credentials)       CREDENTIALS="$2"; shift 2 ;;
    --clients)           CLIENTS="$2"; shift 2 ;;
    --subnets)           SUBNETS="$2"; shift 2 ;;
    --validators-per-pod) VPP="$2"; shift 2 ;;
    --settle)            SETTLE="$2"; shift 2 ;;
    --genesis-offset)    GENESIS_OFFSET="$2"; shift 2 ;;
    --results-dir)       RESULTS_DIR="$2"; shift 2 ;;
    --namespace)         DEVNET_NS="$2"; shift 2 ;;
    --keep)              KEEP=1; shift ;;
    --on-demand)         SPOT=0; shift ;;
    --leanstart)         LEANSTART="$2"; shift 2 ;;
    --ream-image)        REAM_IMAGE_OVERRIDE="$2"; shift 2 ;;
    --cluster)           GKE_CLUSTER="$2"; shift 2 ;;
    --zone)              GKE_ZONE="$2"; shift 2 ;;
    --leaf-machine)      GKE_LEAF_MACHINE="$2"; shift 2 ;;
    --agg-machine)       GKE_AGG_MACHINE="$2"; shift 2 ;;
    --workers-machine)   GKE_WORKERS_MACHINE="$2"; shift 2 ;;
    --project)           GKE_PROJECT="$2"; shift 2 ;;
    --leaf-budget)       LEAF_BUDGET="$2"; shift 2 ;;
    --recursion-budget)  REC_BUDGET="$2"; shift 2 ;;
    --final-slots)       FINAL_SLOTS="$2"; shift 2 ;;
    --window)            WINDOW="$2"; shift 2 ;;
    -h|--help)           sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) gke::err "unknown arg: $1"; exit 1 ;;
  esac
done

[ -n "$CREDENTIALS" ] || { gke::err "--credentials is required"; exit 1; }
[ -n "$CLIENTS" ]     || { gke::err "--clients is required"; exit 1; }
[ -n "$SUBNETS" ]     || { gke::err "--subnets is required"; exit 1; }
case "$SUBNETS" in (*[!0-9]*|"") gke::err "--subnets must be a positive integer"; exit 1 ;; esac

# Resolve the leanstart binary.
if [ -z "$LEANSTART" ]; then
  for cand in "$REPO_ROOT/target/release/leanstart" "$REPO_ROOT/target/debug/leanstart"; do
    [ -x "$cand" ] && { LEANSTART="$cand"; break; }
  done
  [ -z "$LEANSTART" ] && command -v leanstart >/dev/null 2>&1 && LEANSTART="leanstart"
fi
[ -n "$LEANSTART" ] || { gke::err "leanstart binary not found — build it (cargo build) or pass --leanstart"; exit 1; }

# Per-subnet aggregator host labels: agg0,agg1,...
AGG_HOSTS="$(gke::agg_hosts "$SUBNETS")"

# Run metadata for the result record.
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TOTAL_VALIDATORS=0
for spec in $CLIENTS; do
  n="${spec##*:}"; [ "$n" = "$spec" ] && n=1   # "ream" => 1, "ream:4" => 4
  TOTAL_VALIDATORS=$((TOTAL_VALIDATORS + n))
done
TOTAL_VALIDATORS=$((TOTAL_VALIDATORS * VPP * SUBNETS))
# Topology label, sanitized for a filename: "ream4-s1-vpp1".
TOPO_SLUG="$(printf '%s' "$CLIENTS" | tr ' :' '--' | tr -cd 'a-zA-Z0-9-')-s${SUBNETS}-vpp${VPP}"
RUN_ID="${RUN_STAMP}__${TOPO_SLUG}"
LEANSTART_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
REAM_IMAGE="$(grep -oE 'ghcr.io/reamlabs/ream:[^"]*' "$REPO_ROOT/src/config/clients.rs" 2>/dev/null | head -1 || true)"
# --ream-image overrides the pinned image (passed to leanstart via LS_IMAGE_REAM,
# which values.rs honours verbatim) and is recorded as the tested image.
[ -n "$REAM_IMAGE_OVERRIDE" ] && REAM_IMAGE="$REAM_IMAGE_OVERRIDE"

# --- teardown wiring ----------------------------------------------------------
# leanstart's `run` spawns detached `while true; do kubectl logs -f ...; done`
# streamers (one per pod) that it never reaps — they loop forever retrying
# against the (now-deleted) cluster context. Kill them by context so each sweep
# cleans up after itself instead of leaving orphaned shells around.
kill_log_streamers() {
  [ -n "${CTX:-}" ] || return 0
  pkill -9 -f "$CTX logs" 2>/dev/null || true
}

# Save every devnet pod's logs to results/logs/<run_id>/ before the cluster is
# deleted — otherwise they vanish with it. Aggregator pods are the per-subnet
# first pod (ream-s0-p0-0, ream-s1-p0-0, ...); they're the ones to read when a
# multi-subnet topology won't finalize. Best-effort; never blocks teardown.
capture_pod_logs() {
  [ -n "${CTX:-}" ] || return 0
  local dir="$RESULTS_DIR/logs/$RUN_ID"
  mkdir -p "$dir" || return 0
  gke::log "Capturing devnet pod logs -> $dir/"
  kubectl --context "$CTX" -n "$DEVNET_NS" get pods -o wide >"$dir/_pods.txt" 2>&1 || true
  local pods
  pods="$(kubectl --context "$CTX" -n "$DEVNET_NS" get pods -o name 2>/dev/null)" || return 0
  for p in $pods; do
    local name="${p#pod/}"
    kubectl --context "$CTX" -n "$DEVNET_NS" logs "$p" --all-containers --prefix --tail=-1 \
      >"$dir/${name}.log" 2>&1 || true
  done
}

teardown() {
  local rc=$?
  trap - EXIT
  capture_pod_logs
  kill_log_streamers
  if [ "$KEEP" = "1" ]; then
    gke::log "--keep set: leaving cluster '$GKE_CLUSTER' up. Tear down with gke-down.sh."
    gke::log "  scoped CLOUDSDK_CONFIG=$CLOUDSDK_CONFIG  KUBECONFIG=$KUBECONFIG"
    exit "$rc"
  fi
  # Delete the devnet's PVCs first so the in-cluster CSI driver reclaims the
  # backing hyperdisks. Deleting the cluster directly orphans them, leaking the
  # regional HDB_TOTAL_GB quota. --wait blocks on the PV finalizers (= the PD
  # actually being deleted).
  if [ -n "${CTX:-}" ]; then
    gke::log "Reclaiming devnet PVCs before cluster delete (avoids leaked disks)..."
    kubectl --context "$CTX" delete pvc --all -n "$DEVNET_NS" --wait=true --timeout=150s >&2 2>/dev/null || true
  fi
  gke::cluster_down "$GKE_CLUSTER" || gke::err "cluster teardown failed — check console! cluster=$GKE_CLUSTER zone=$GKE_ZONE"
  gke::cleanup
  exit "$rc"
}

gke::auth "$CREDENTIALS"
trap teardown EXIT INT TERM   # replaces gke::auth's cleanup-only trap

# --- 1. provision -------------------------------------------------------------
# Explicit check: `set -e` doesn't reliably propagate a failure out of a
# function run in command substitution, so test it directly. On failure the
# EXIT trap tears down whatever partial cluster exists.
if ! CTX="$(gke::cluster_up "$GKE_CLUSTER" "$SUBNETS" "$SPOT")" || [ -z "$CTX" ]; then
  gke::err "cluster provisioning failed (see above)."
  exit 1
fi

# --- 2. deploy the devnet -----------------------------------------------------
# On a deploy failure, dump scheduling diagnostics BEFORE the EXIT trap tears
# the cluster down — otherwise the reason is lost with the cluster.
diagnose() {
  gke::err "Deploy failed — capturing scheduling diagnostics:"
  kubectl --context "$CTX" get pods -n "$DEVNET_NS" -o wide >&2 2>&1 || true
  kubectl --context "$CTX" get nodes -L "$GKE_HOST_LABEL_KEY" -L leanstart.io/pool >&2 2>&1 || true
  kubectl --context "$CTX" describe pods -n "$DEVNET_NS" 2>&1 | grep -iE "Name:|Status:|Node:|Events:|Warning|FailedScheduling|taint|nodeSelector|Insufficient|claim" >&2 || true
  kubectl --context "$CTX" get events -n "$DEVNET_NS" --sort-by=.lastTimestamp 2>&1 | tail -25 >&2 || true
}

gke::log "Deploying devnet: clients='$CLIENTS' subnets=$SUBNETS vpp=$VPP aggregators=[$AGG_HOSTS]"
# shellcheck disable=SC2086  # CLIENTS is intentionally word-split into specs
if ! env ${REAM_IMAGE_OVERRIDE:+LS_IMAGE_REAM="$REAM_IMAGE_OVERRIDE"} "$LEANSTART" run $CLIENTS \
  --subnets "$SUBNETS" \
  --validators-per-pod "$VPP" \
  --aggregator-hosts "$AGG_HOSTS" \
  --genesis-offset "$GENESIS_OFFSET" \
  --namespace "$DEVNET_NS" \
  --skip-kind --context "$CTX" >&2; then
  diagnose
  exit 1
fi

# --- 3. settle ----------------------------------------------------------------
# Poll the chain on an interval instead of a blank sleep, so the log shows live
# head/justified/finalized movement (and never goes quiet for 10 minutes).
# watch-progress always exits 0; fall back to a plain sleep if it can't run.
"$SCRIPT_DIR/watch-progress.sh" --context "$CTX" --namespace "$DEVNET_NS" \
  --duration "$SETTLE" --interval "${SETTLE_POLL_INTERVAL:-30}" \
  || { gke::err "watch-progress failed; falling back to plain sleep"; sleep "$SETTLE"; }

# --- 4. measure ---------------------------------------------------------------
mkdir -p "$RESULTS_DIR"
MEAS_JSON="$RESULTS_DIR/$RUN_ID.measurements.json"
CB_ARGS=(--context "$CTX" --namespace "$DEVNET_NS" --label "$CLIENTS|s=$SUBNETS|vpp=$VPP"
         --json-out "$MEAS_JSON")
[ -n "$LEAF_BUDGET" ]  && CB_ARGS+=(--leaf-budget "$LEAF_BUDGET")
[ -n "$REC_BUDGET" ]   && CB_ARGS+=(--recursion-budget "$REC_BUDGET")
[ -n "$FINAL_SLOTS" ]  && CB_ARGS+=(--final-slots "$FINAL_SLOTS")
[ -n "$WINDOW" ]       && CB_ARGS+=(--window "$WINDOW")
"$SCRIPT_DIR/check-budgets.sh" "${CB_ARGS[@]}" || gke::err "check-budgets reported a failure"

# --- 5. record per-run JSON + consolidated CSV --------------------------------
LS_RESULTS_DIR="$RESULTS_DIR" LS_RUN_ID="$RUN_ID" LS_TIMESTAMP="$TIMESTAMP" \
LS_STATUS="error" LS_MEASUREMENTS_JSON="$MEAS_JSON" \
LS_CLIENTS="$CLIENTS" LS_SUBNETS="$SUBNETS" LS_VPP="$VPP" \
LS_TOTAL_VALIDATORS="$TOTAL_VALIDATORS" LS_AGG_HOSTS="$AGG_HOSTS" \
LS_LEAF_MACHINE="$GKE_LEAF_MACHINE" LS_AGG_MACHINE="$GKE_AGG_MACHINE" \
LS_WORKERS_MACHINE="$GKE_WORKERS_MACHINE" LS_ZONE="$GKE_ZONE" LS_SPOT="$SPOT" \
LS_GENESIS_OFFSET="$GENESIS_OFFSET" LS_SETTLE="$SETTLE" LS_WINDOW="${WINDOW:-2m}" \
LS_CLUSTER="$GKE_CLUSTER" LS_PROJECT="$GKE_PROJECT" \
LS_LEANSTART_SHA="$LEANSTART_SHA" LS_REAM_IMAGE="$REAM_IMAGE" \
  python3 "$SCRIPT_DIR/record_result.py" || gke::err "record_result failed"
# Drop the intermediate measurements file (its content is now in the per-run JSON).
rm -f "$MEAS_JSON"

# --- 6. teardown via EXIT trap ------------------------------------------------
gke::log "Sweep complete. Results in $RESULTS_DIR/ (per-run JSON + consolidated.csv)"
