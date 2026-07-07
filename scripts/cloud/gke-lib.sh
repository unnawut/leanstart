#!/usr/bin/env bash
# gke-lib.sh — shared helpers for the leanstart GKE topology-sweep tooling.
#
# Sourced by gke-up.sh / gke-down.sh / gke-sweep.sh. Provides fully-scoped GCP
# auth so nothing touches the caller's personal gcloud/kubectl session:
#
#   * gcloud auth + project are activated inside a throwaway CLOUDSDK_CONFIG dir
#     from a service-account key (mirrors leanBench's provisioner isolation).
#   * KUBECONFIG points at a throwaway file in the same dir, so cluster
#     credentials never land in ~/.kube/config.
#   * The GKE kubeconfig entry uses gke-gcloud-auth-plugin, which reads
#     CLOUDSDK_CONFIG at exec time — so exporting it here means kubectl/helm
#     (and leanstart's --skip-kind path) all authenticate as the same SA.
#
# Both env vars are exported into the current shell; call gke::cleanup (wired to
# an EXIT trap by gke::auth) to wipe the temp dir.

set -euo pipefail

# --- project-local .env -------------------------------------------------------
# Load a project .env (credentials path + GKE_* overrides) BEFORE the defaults
# below, so values there take effect. Search order: $LEANSTART_ENV, then the
# repo-root .env, then ./.env. A relative GKE_CREDENTIALS in a repo-root .env is
# resolved relative to the repo root so it works from any working directory.
gke::_load_env() {
  local lib_dir repo_root cand env_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$lib_dir/../.." && pwd)"
  for cand in "${LEANSTART_ENV:-}" "$repo_root/.env" "./.env"; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    set -a; . "$cand"; set +a
    # Resolve a relative credentials path against the .env's own directory.
    if [ -n "${GKE_CREDENTIALS:-}" ] && [ "${GKE_CREDENTIALS#/}" = "$GKE_CREDENTIALS" ]; then
      env_dir="$(cd "$(dirname "$cand")" && pwd)"
      GKE_CREDENTIALS="$env_dir/$GKE_CREDENTIALS"
    fi
    export GKE_CREDENTIALS
    return 0
  done
}
gke::_load_env

# --- configuration defaults (override via env or flags in the callers) --------
: "${GKE_ZONE:=us-central1-a}"
# Non-aggregator (leaf attester) pods run on the workers pool — both default to
# a small 4-vCPU machine, since the leaf-aggregation and recursion work the
# budgets measure happens on the AGGREGATOR node, not here. leaf_machine is
# recorded for provenance and kept equal to the workers machine (where these
# pods actually land). The aggregator is the binding tier — see README for the
# lean-bench-derived rationale.
: "${GKE_LEAF_MACHINE:=c4-standard-4}"
: "${GKE_AGG_MACHINE:=c4-standard-32}"
# Workers pool: non-aggregator client pods, bootnodes, and the metrics stack.
: "${GKE_WORKERS_MACHINE:=c4-standard-4}"
: "${GKE_WORKERS_MIN:=1}"
: "${GKE_WORKERS_MAX:=4}"
# Node boot-disk size (GB). c4 nodes use hyperdisk boot disks that count against
# the regional HDB_TOTAL_GB quota; 20GB holds the OS + container images for
# these ephemeral nodes and is 1/5 the 100GB default, minimizing HDB pressure.
: "${GKE_NODE_DISK_GB:=20}"
# Host-label prefix for per-subnet aggregator nodes: agg0, agg1, ...
: "${GKE_HOST_LABEL_PREFIX:=agg}"
# Kubernetes node label key leanstart uses for @host / --aggregator-hosts pins.
: "${GKE_HOST_LABEL_KEY:=leanstart.io/host}"

# --- internal state -----------------------------------------------------------
GKE_CFG_DIR=""

# gke::log MSG... — stderr progress line (stdout is reserved for return values
# like the cluster context, so callers can capture it cleanly).
gke::log() { printf '\033[1;35m==>\033[0m %s\n' "$*" >&2; }
gke::err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }

gke::require() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      gke::err "required command not found: $c"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
}

# gke::cleanup — remove the scoped config dir. Idempotent; safe in traps.
gke::cleanup() {
  if [ -n "${GKE_CFG_DIR:-}" ] && [ -d "$GKE_CFG_DIR" ]; then
    rm -rf "$GKE_CFG_DIR"
    GKE_CFG_DIR=""
  fi
}

# gke::auth CREDENTIALS_JSON — activate the SA in a scoped config dir and export
# CLOUDSDK_CONFIG + KUBECONFIG. Sets GKE_PROJECT from the key's project_id
# unless GKE_PROJECT is already set. Installs an EXIT trap for cleanup.
gke::auth() {
  local creds="$1"
  [ -f "$creds" ] || { gke::err "credentials file not found: $creds"; exit 1; }
  gke::require gcloud kubectl

  GKE_CFG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/leanstart-gke.XXXXXX")"
  trap gke::cleanup EXIT
  export CLOUDSDK_CONFIG="$GKE_CFG_DIR/gcloud"
  export KUBECONFIG="$GKE_CFG_DIR/kubeconfig"
  mkdir -p "$CLOUDSDK_CONFIG"

  if [ -z "${GKE_PROJECT:-}" ]; then
    # Pull project_id straight from the key JSON (no jq dependency).
    GKE_PROJECT="$(sed -n 's/.*"project_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$creds" | head -1)"
    [ -n "$GKE_PROJECT" ] || { gke::err "could not read project_id from $creds; set GKE_PROJECT"; exit 1; }
  fi
  export GKE_PROJECT

  gke::log "Activating service account (scoped) for project $GKE_PROJECT"
  gcloud auth activate-service-account --key-file "$creds" --quiet >/dev/null
  gcloud config set project "$GKE_PROJECT" --quiet >/dev/null

  # The GKE kubeconfig auth provider shells out to this plugin by name, so it
  # must be on PATH. Homebrew's gcloud SDK keeps it in <sdk_root>/bin without
  # symlinking that dir into /opt/homebrew/bin, so add it ourselves when needed.
  if ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    local sdk_bin
    sdk_bin="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)/bin"
    if [ -x "$sdk_bin/gke-gcloud-auth-plugin" ]; then
      export PATH="$sdk_bin:$PATH"
      gke::log "Added $sdk_bin to PATH (gke-gcloud-auth-plugin)"
    fi
  fi
  if ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    gke::err "gke-gcloud-auth-plugin not found. Install it with:"
    gke::err "  gcloud components install gke-gcloud-auth-plugin"
    gke::err "  (or: apt-get install google-cloud-cli-gke-gcloud-auth-plugin)"
    exit 1
  fi
}

# gke::context CLUSTER — the kubeconfig context name get-credentials writes.
gke::context() { printf 'gke_%s_%s_%s' "$GKE_PROJECT" "$GKE_ZONE" "$1"; }

# gke::agg_hosts N — comma-separated per-subnet aggregator labels: "agg0,agg1".
# Hand-rolled (not `seq -s,`) because BSD/macOS seq appends a trailing
# separator, which would feed leanstart an empty label.
gke::agg_hosts() {
  local n="$1" i out=""
  for ((i = 0; i < n; i++)); do out="${out:+$out,}${GKE_HOST_LABEL_PREFIX}${i}"; done
  printf '%s' "$out"
}

# gke::cluster_up CLUSTER SUBNETS [spot:1|0] — create a zonal cluster with a
# workers pool plus one labelled 1-node aggregator pool per subnet, then fetch
# credentials. Reads GKE_* machine/zone vars. Prints the context on stdout.
# Requires gke::auth to have run first (scoped env exported).
gke::cluster_up() {
  local cluster="$1" subnets="$2" spot="${3:-1}"
  local spot_flag=""; [ "$spot" = "1" ] && spot_flag="--spot"
  gke::require gcloud kubectl

  gke::log "Creating GKE cluster '$cluster' in $GKE_ZONE (project $GKE_PROJECT)"
  gke::log "  leaf=$GKE_LEAF_MACHINE  aggregator=$GKE_AGG_MACHINE (spot=$spot)  workers=$GKE_WORKERS_MACHINE (on-demand)"

  # Workers pool is ON-DEMAND (untainted): it hosts the kube-prometheus-stack
  # metrics pods + non-aggregator client pods, which carry no Spot toleration.
  # Only the (expensive c4) aggregator pools below use Spot, where the savings
  # matter and leanstart's pods tolerate the Spot taint.
  gcloud container clusters create "$cluster" \
    --zone "$GKE_ZONE" --node-locations "$GKE_ZONE" \
    --num-nodes "$GKE_WORKERS_MIN" --machine-type "$GKE_WORKERS_MACHINE" \
    --disk-size "$GKE_NODE_DISK_GB" \
    --enable-autoscaling --min-nodes "$GKE_WORKERS_MIN" --max-nodes "$GKE_WORKERS_MAX" \
    --node-labels "leanstart.io/pool=workers" \
    --no-enable-basic-auth --no-issue-client-certificate \
    --quiet >&2

  local i label
  for i in $(seq 0 $((subnets - 1))); do
    label="${GKE_HOST_LABEL_PREFIX}${i}"
    gke::log "Creating aggregator node pool '$label' ($GKE_AGG_MACHINE)"
    # Explicit failure check: `set -e` does not reliably abort inside a function
    # run via command substitution, so a failed pool-create would otherwise be
    # ignored and surface 3 minutes later as an opaque scheduling failure.
    # shellcheck disable=SC2086
    if ! gcloud container node-pools create "$label" \
      --cluster "$cluster" --zone "$GKE_ZONE" \
      --num-nodes 1 --machine-type "$GKE_AGG_MACHINE" \
      --disk-size "$GKE_NODE_DISK_GB" \
      --node-labels "${GKE_HOST_LABEL_KEY}=${label},leanstart.io/pool=aggregator" \
      $spot_flag \
      --quiet >&2; then
      gke::err "Failed to create aggregator node pool '$label' ($GKE_AGG_MACHINE)."
      gke::err "Likely GCP vCPU quota: workers ($GKE_WORKERS_MACHINE) + $subnets x $GKE_AGG_MACHINE"
      gke::err "aggregators. Check/raise CPUS_ALL_REGIONS for project $GKE_PROJECT, or use a"
      gke::err "smaller --agg-machine. (The caller tears down the partial cluster.)"
      return 1
    fi
  done

  gke::log "Fetching cluster credentials into scoped KUBECONFIG"
  gcloud container clusters get-credentials "$cluster" --zone "$GKE_ZONE" --quiet >&2

  local ctx; ctx="$(gke::context "$cluster")"
  kubectl --context "$ctx" get nodes -L "$GKE_HOST_LABEL_KEY" -L leanstart.io/pool >&2
  gke::setup_storage "$ctx"
  printf '%s\n' "$ctx"
}

# gke::setup_storage CTX — make hyperdisk-balanced the default StorageClass.
# The C3/C4 machine families don't support pd-* persistent disks, so GKE's stock
# default (standard-rwo = pd-balanced) fails to attach on c4 nodes with
# "pd-balanced disk type cannot be used by c4-... machine type". leanstart's
# data PVCs set no storageClassName, so they follow the cluster default — point
# that at hyperdisk-balanced, which c4 supports.
gke::setup_storage() {
  local ctx="$1" sc
  gke::log "Setting hyperdisk-balanced as default StorageClass (c4-compatible)"
  # Drop the default flag from any stock pd-* default classes.
  for sc in standard-rwo premium-rwo standard; do
    kubectl --context "$ctx" patch storageclass "$sc" \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
      >/dev/null 2>&1 || true
  done
  kubectl --context "$ctx" apply -f - >&2 <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: leanstart-hyperdisk
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: pd.csi.storage.gke.io
parameters:
  type: hyperdisk-balanced
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
YAML
}

# gke::cluster_down CLUSTER — delete the cluster, tolerating already-gone.
gke::cluster_down() {
  local cluster="$1"
  gke::log "Deleting GKE cluster '$cluster' in $GKE_ZONE"
  if gcloud container clusters delete "$cluster" --zone "$GKE_ZONE" --quiet >&2 2>"$GKE_CFG_DIR/.del.err"; then
    return 0
  fi
  if grep -qiE "not found|was not found|already being deleted" "$GKE_CFG_DIR/.del.err" 2>/dev/null; then
    gke::log "Cluster already gone — nothing to delete"
    return 0
  fi
  cat "$GKE_CFG_DIR/.del.err" >&2 || true
  return 1
}

# gke::cluster_exists CLUSTER — true if the cluster is present in $GKE_ZONE.
gke::cluster_exists() {
  gcloud container clusters describe "$1" --zone "$GKE_ZONE" >/dev/null 2>&1
}

# gke::pool_exists CLUSTER POOL — true if the node pool exists.
gke::pool_exists() {
  gcloud container node-pools describe "$2" --cluster "$1" --zone "$GKE_ZONE" >/dev/null 2>&1
}

# gke::wait_nodes_ready CTX WANT — block until >= WANT nodes report Ready (after
# a scale-from-0, fresh nodes need ~2-3 min to boot+register before pods bind).
gke::wait_nodes_ready() {
  local ctx="$1" want="$2" i ready
  gke::log "Waiting for >= $want nodes Ready..."
  for ((i = 0; i < 60; i++)); do
    # match the STATUS column exactly so NotReady doesn't count.
    ready="$(kubectl --context "$ctx" get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | grep -c . || true)"
    [ "${ready:-0}" -ge "$want" ] && { gke::log "  $ready nodes Ready"; return 0; }
    sleep 10
  done
  gke::err "timeout waiting for nodes Ready (have ${ready:-0}/$want)"
  return 1
}

# gke::scale_pools CLUSTER SUBNETS up|down [spot] — bring the workers pool and
# the per-subnet aggregator pools to 1 node each (up), creating any missing agg
# pool, or to 0 nodes (down/idle). Scaling to 0 keeps the (free) control plane
# and the monitoring stack's config while dropping all billable compute.
gke::scale_pools() {
  local cluster="$1" subnets="$2" state="$3" spot="${4:-1}"
  local spot_flag=""; [ "$spot" = "1" ] && spot_flag="--spot"

  # The workers pool is whatever non-aggregator pool exists. gke::cluster_up
  # makes it via `clusters create`, so GKE names it "default-pool" (NOT
  # "workers" — only its node LABEL is leanstart.io/pool=workers). Detect it by
  # name so resize/scale target the real pool instead of silently no-op'ing.
  local wpool
  wpool="$(gcloud container node-pools list --cluster "$cluster" --zone "$GKE_ZONE" \
             --format='value(name)' 2>/dev/null | grep -v "^${GKE_HOST_LABEL_PREFIX}" | head -1)"
  [ -n "$wpool" ] || wpool="default-pool"

  if [ "$state" = "down" ]; then
    gke::log "Scaling cluster '$cluster' to 0 nodes (idle — control plane is free)"
    gcloud container clusters update "$cluster" --zone "$GKE_ZONE" \
      --enable-autoscaling --min-nodes 0 --max-nodes "$GKE_WORKERS_MAX" \
      --node-pool "$wpool" --quiet >&2 2>/dev/null || true
    gcloud container clusters resize "$cluster" --zone "$GKE_ZONE" \
      --node-pool "$wpool" --num-nodes 0 --quiet >&2 2>/dev/null || true
    local p
    for p in $(gcloud container node-pools list --cluster "$cluster" --zone "$GKE_ZONE" \
                 --format='value(name)' 2>/dev/null | grep "^${GKE_HOST_LABEL_PREFIX}"); do
      gcloud container clusters resize "$cluster" --zone "$GKE_ZONE" \
        --node-pool "$p" --num-nodes 0 --quiet >&2 2>/dev/null || true
    done
    return 0
  fi

  # state = up
  gke::log "Scaling cluster '$cluster' up for $subnets subnet(s)"
  gcloud container clusters update "$cluster" --zone "$GKE_ZONE" \
    --enable-autoscaling --min-nodes "$GKE_WORKERS_MIN" --max-nodes "$GKE_WORKERS_MAX" \
    --node-pool "$wpool" --quiet >&2 2>/dev/null || true
  gcloud container clusters resize "$cluster" --zone "$GKE_ZONE" \
    --node-pool "$wpool" --num-nodes "$GKE_WORKERS_MIN" --quiet >&2 2>/dev/null || true
  local i label
  for i in $(seq 0 $((subnets - 1))); do
    label="${GKE_HOST_LABEL_PREFIX}${i}"
    if gke::pool_exists "$cluster" "$label"; then
      gcloud container clusters resize "$cluster" --zone "$GKE_ZONE" \
        --node-pool "$label" --num-nodes 1 --quiet >&2 2>/dev/null || true
    else
      gke::log "Creating missing aggregator pool '$label' ($GKE_AGG_MACHINE)"
      # shellcheck disable=SC2086
      gcloud container node-pools create "$label" \
        --cluster "$cluster" --zone "$GKE_ZONE" \
        --num-nodes 1 --machine-type "$GKE_AGG_MACHINE" --disk-size "$GKE_NODE_DISK_GB" \
        --node-labels "${GKE_HOST_LABEL_KEY}=${label},leanstart.io/pool=aggregator" \
        $spot_flag --quiet >&2 || return 1
    fi
  done
}

# gke::ensure_cluster CLUSTER SUBNETS [spot] — reuse an existing cluster (scaling
# its pools back up, creating extra agg pools if SUBNETS grew) or create a fresh
# one. Prints the context on stdout, like gke::cluster_up.
gke::ensure_cluster() {
  local cluster="$1" subnets="$2" spot="${3:-1}"
  if gke::cluster_exists "$cluster"; then
    gke::log "Reusing existing cluster '$cluster' in $GKE_ZONE"
    gcloud container clusters get-credentials "$cluster" --zone "$GKE_ZONE" --quiet >&2
    local ctx; ctx="$(gke::context "$cluster")"
    gke::scale_pools "$cluster" "$subnets" up "$spot" || return 1
    gke::setup_storage "$ctx"                                  # idempotent
    gke::wait_nodes_ready "$ctx" "$((subnets + GKE_WORKERS_MIN))" || return 1
    printf '%s\n' "$ctx"
  else
    gke::cluster_up "$cluster" "$subnets" "$spot"
  fi
}
