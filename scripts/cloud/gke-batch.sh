#!/usr/bin/env bash
# gke-batch.sh — run many topology/image configs on ONE reused GKE cluster.
#
# The per-run cluster create + kube-prometheus-stack install + teardown is ~26
# min of overhead that gke-sweep.sh pays for EVERY config. This batches them:
# provision (or reuse) the cluster once, install metrics once, then loop
# deploy -> settle -> measure -> record -> wipe-namespace per config, and at the
# end SCALE NODE POOLS TO 0 (idle) instead of deleting — so the (free) control
# plane and the metrics stack persist for the next session, while billable
# compute drops to ~$0. Re-invoking scales the same cluster back up in ~2-3 min.
#
# Usage:
#   gke-batch.sh --credentials <key.json> --batch <file> [options]
#
# Batch file: one config per line, whitespace-separated, '#' comments ignored:
#   # clients   subnets vpp image
#   ream:3      2       1   avx2-v3
#   ream:3      2       1   avx512-v4
#   ream:4      1       8   avx512-v4
# image column: full ref (has '/'), a bare tag resolved under $LS_REAM_REPO,
#   or '-'/empty for the pinned default in clients.rs.
#
# End-of-batch disposition (default: --idle):
#   --idle        scale node pools to 0; keep cluster + metrics (cheapest reuse)
#   --keep-up     leave nodes running (fastest next run, full compute cost)
#   --teardown    reclaim PVCs and delete the cluster entirely
#
# Other options mirror gke-sweep.sh: --settle --genesis-offset --window
#   --agg-machine --workers-machine --zone --project --cluster --leanstart
#   --results-dir --namespace --on-demand --leaf-budget --recursion-budget
#   --final-slots

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/cloud/gke-lib.sh
source "$SCRIPT_DIR/gke-lib.sh"

CREDENTIALS="${GKE_CREDENTIALS:-}"; BATCH_FILE=""
SETTLE=300; GENESIS_OFFSET=150; RESULTS_DIR="./results"; DEVNET_NS="lean-devnet"
SPOT=1; LEANSTART=""; DISPOSITION="idle"
LS_REAM_REPO="${LS_REAM_REPO:-us-central1-docker.pkg.dev/lean-pqinterop/leanstart/ream}"
: "${GKE_CLUSTER:=leanstart-sweep}"
LEAF_BUDGET=""; REC_BUDGET=""; FINAL_SLOTS=""; WINDOW=""

while [ $# -gt 0 ]; do
  case "$1" in
    --credentials)       CREDENTIALS="$2"; shift 2 ;;
    --batch)             BATCH_FILE="$2"; shift 2 ;;
    --settle)            SETTLE="$2"; shift 2 ;;
    --genesis-offset)    GENESIS_OFFSET="$2"; shift 2 ;;
    --results-dir)       RESULTS_DIR="$2"; shift 2 ;;
    --namespace)         DEVNET_NS="$2"; shift 2 ;;
    --on-demand)         SPOT=0; shift ;;
    --leanstart)         LEANSTART="$2"; shift 2 ;;
    --idle)              DISPOSITION="idle"; shift ;;
    --keep-up)           DISPOSITION="keep-up"; shift ;;
    --teardown)          DISPOSITION="teardown"; shift ;;
    --cluster)           GKE_CLUSTER="$2"; shift 2 ;;
    --zone)              GKE_ZONE="$2"; shift 2 ;;
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
[ -n "$BATCH_FILE" ] && [ -f "$BATCH_FILE" ] || { gke::err "--batch <file> is required and must exist"; exit 1; }

# Resolve the leanstart binary (same autodetect as gke-sweep.sh).
if [ -z "$LEANSTART" ]; then
  for cand in "$REPO_ROOT/target/release/leanstart" "$REPO_ROOT/target/debug/leanstart"; do
    [ -x "$cand" ] && { LEANSTART="$cand"; break; }
  done
  [ -z "$LEANSTART" ] && command -v leanstart >/dev/null 2>&1 && LEANSTART="leanstart"
fi
[ -n "$LEANSTART" ] || { gke::err "leanstart binary not found — build it (cargo build) or pass --leanstart"; exit 1; }

# --- parse the batch file -----------------------------------------------------
B_CLIENTS=(); B_SUBNETS=(); B_VPP=(); B_IMAGE=(); MAX_SUBNETS=1
while read -r clients subnets vpp image _rest; do
  [ -z "${clients:-}" ] && continue
  case "$clients" in \#*) continue ;; esac
  : "${subnets:=1}"; : "${vpp:=1}"; : "${image:=-}"
  B_CLIENTS+=("$clients"); B_SUBNETS+=("$subnets"); B_VPP+=("$vpp"); B_IMAGE+=("$image")
  [ "$subnets" -gt "$MAX_SUBNETS" ] && MAX_SUBNETS="$subnets"
done < "$BATCH_FILE"
N=${#B_CLIENTS[@]}
[ "$N" -gt 0 ] || { gke::err "no configs parsed from $BATCH_FILE"; exit 1; }
gke::log "Batch: $N config(s), max subnets=$MAX_SUBNETS, disposition=$DISPOSITION"

# image column -> full ref ('' means no override / pinned default).
expand_image() {
  case "$1" in
    ""|"-")  printf '' ;;
    */*)     printf '%s' "$1" ;;
    *)       printf '%s:%s' "$LS_REAM_REPO" "$1" ;;
  esac
}

CTX=""
kill_log_streamers() { [ -n "${CTX:-}" ] && pkill -9 -f "$CTX logs" 2>/dev/null || true; }

# Save every devnet pod's logs to results/logs/<run_id>/ BEFORE the namespace is
# wiped — otherwise crash/incompat diagnostics vanish with it. Best-effort.
capture_pod_logs() {
  [ -n "${CTX:-}" ] || return 0
  local dir="$RESULTS_DIR/logs/${RUN_ID:-batch-unknown}"
  mkdir -p "$dir" || return 0
  kubectl --context "$CTX" -n "$DEVNET_NS" get pods -o wide >"$dir/_pods.txt" 2>&1 || true
  local p
  for p in $(kubectl --context "$CTX" -n "$DEVNET_NS" get pods -o name 2>/dev/null); do
    kubectl --context "$CTX" -n "$DEVNET_NS" logs "$p" --all-containers --prefix --tail=-1 \
      >"$dir/${p#pod/}.log" 2>&1 || true
  done
}

# Wipe the devnet namespace + reclaim its PVCs (so the backing hyperdisks are
# released, not leaked) between configs and before teardown. Captures pod logs
# first so a failed/incompatible run leaves diagnostics behind.
wipe_devnet() {
  [ -n "${CTX:-}" ] || return 0
  capture_pod_logs
  kill_log_streamers
  kubectl --context "$CTX" delete pvc --all -n "$DEVNET_NS" --wait=true --timeout=150s >/dev/null 2>&1 || true
  kubectl --context "$CTX" delete namespace "$DEVNET_NS" --wait=true --timeout=150s >/dev/null 2>&1 || true
}

# EXIT/signal trap: clean the last devnet, then apply the chosen disposition.
finish() {
  local rc=$?
  trap - EXIT INT TERM
  # --keep-up leaves the full devnet running for manual inspection; the others
  # wipe it (reclaiming its disks) before parking/deleting the cluster.
  [ "$DISPOSITION" = "keep-up" ] || wipe_devnet
  case "$DISPOSITION" in
    teardown)
      # Reclaim ALL PVCs cluster-wide (devnet already wiped above, but the
      # monitoring namespace's Prometheus PVC would otherwise orphan its
      # hyperdisk when the cluster is deleted). --wait blocks on PD deletion.
      [ -n "${CTX:-}" ] && kubectl --context "$CTX" delete pvc --all -A --wait=true --timeout=150s >/dev/null 2>&1 || true
      gke::cluster_down "$GKE_CLUSTER" || gke::err "cluster teardown failed — check console! cluster=$GKE_CLUSTER" ;;
    keep-up)  gke::log "--keep-up: leaving cluster '$GKE_CLUSTER' running (billing continues). Idle with: gke-down.sh --idle" ;;
    idle)     gke::scale_pools "$GKE_CLUSTER" "$MAX_SUBNETS" down "$SPOT" ;;
  esac
  gke::cleanup
  exit "$rc"
}

gke::auth "$CREDENTIALS"
trap finish EXIT INT TERM

# --- provision or reuse the cluster once --------------------------------------
if ! CTX="$(gke::ensure_cluster "$GKE_CLUSTER" "$MAX_SUBNETS" "$SPOT")" || [ -z "$CTX" ]; then
  gke::err "cluster provisioning/reuse failed (see above)."
  exit 1
fi

# Every config installs metrics (no --skip-metrics). leanstart ties the devnet's
# ServiceMonitor to the same flag (helm value prometheus.enabled = !skip_metrics,
# see run.rs:277), and we wipe the devnet namespace between configs — so skipping
# would leave the new pods un-scraped (all metrics n/a). The heavy
# kube-prometheus-stack install is an idempotent `helm upgrade --install` that is
# a fast no-op once present, so re-running it per config is cheap and correct.

# --- loop over configs --------------------------------------------------------
for ((idx = 0; idx < N; idx++)); do
  CLIENTS="${B_CLIENTS[$idx]}"; SUBNETS="${B_SUBNETS[$idx]}"; VPP="${B_VPP[$idx]}"
  IMG="$(expand_image "${B_IMAGE[$idx]}")"
  AGG_HOSTS="$(gke::agg_hosts "$SUBNETS")"

  TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  TOTAL_VALIDATORS=0
  for spec in $CLIENTS; do n="${spec##*:}"; [ "$n" = "$spec" ] && n=1; TOTAL_VALIDATORS=$((TOTAL_VALIDATORS + n)); done
  TOTAL_VALIDATORS=$((TOTAL_VALIDATORS * VPP * SUBNETS))
  TOPO_SLUG="$(printf '%s' "$CLIENTS" | tr ' :' '--' | tr -cd 'a-zA-Z0-9-')-s${SUBNETS}-vpp${VPP}"
  RUN_ID="${RUN_STAMP}__${TOPO_SLUG}"
  LEANSTART_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  REAM_IMAGE="$(grep -oE 'ghcr.io/reamlabs/ream:[^"]*' "$REPO_ROOT/src/config/clients.rs" 2>/dev/null | head -1 || true)"
  [ -n "$IMG" ] && REAM_IMAGE="$IMG"

  gke::log "[$((idx + 1))/$N] $CLIENTS subnets=$SUBNETS vpp=$VPP image=${REAM_IMAGE##*/}"

  # shellcheck disable=SC2086
  if ! env ${IMG:+LS_IMAGE_REAM="$IMG"} "$LEANSTART" run $CLIENTS \
      --subnets "$SUBNETS" --validators-per-pod "$VPP" \
      --aggregator-hosts "$AGG_HOSTS" --genesis-offset "$GENESIS_OFFSET" \
      --namespace "$DEVNET_NS" --skip-kind --context "$CTX" >&2; then
    gke::err "deploy failed for config $((idx + 1)) ($CLIENTS s=$SUBNETS) — skipping to next"
    kubectl --context "$CTX" get pods -n "$DEVNET_NS" -o wide >&2 2>&1 || true
    wipe_devnet
    continue
  fi

  # settle
  "$SCRIPT_DIR/watch-progress.sh" --context "$CTX" --namespace "$DEVNET_NS" \
    --duration "$SETTLE" --interval "${SETTLE_POLL_INTERVAL:-30}" \
    || { gke::err "watch-progress failed; plain sleep"; sleep "$SETTLE"; }

  # measure
  mkdir -p "$RESULTS_DIR"
  MEAS_JSON="$RESULTS_DIR/$RUN_ID.measurements.json"
  CB_ARGS=(--context "$CTX" --namespace "$DEVNET_NS" --label "$CLIENTS|s=$SUBNETS|vpp=$VPP" --json-out "$MEAS_JSON")
  [ -n "$LEAF_BUDGET" ] && CB_ARGS+=(--leaf-budget "$LEAF_BUDGET")
  [ -n "$REC_BUDGET" ]  && CB_ARGS+=(--recursion-budget "$REC_BUDGET")
  [ -n "$FINAL_SLOTS" ] && CB_ARGS+=(--final-slots "$FINAL_SLOTS")
  [ -n "$WINDOW" ]      && CB_ARGS+=(--window "$WINDOW")
  "$SCRIPT_DIR/check-budgets.sh" "${CB_ARGS[@]}" || gke::err "check-budgets reported a failure"

  # record
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
  rm -f "$MEAS_JSON"

  # wipe before the next config (clean slate; reclaims hyperdisks). Skip on the
  # final config — the EXIT trap handles it alongside the disposition.
  [ "$idx" -lt "$((N - 1))" ] && { gke::log "Wiping devnet before next config..."; wipe_devnet; }
done

gke::log "Batch complete ($N configs). Applying disposition: $DISPOSITION"
# finish() runs via the EXIT trap.
