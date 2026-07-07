#!/usr/bin/env bash
# gke-up.sh — standalone: provision an ephemeral GKE cluster for a topology
# sweep and leave it running so you can drive leanstart against it by hand.
#
# For the full automated up -> run -> check -> down flow, use gke-sweep.sh.
# This wrapper is for manual poking: it creates the cluster, then prints the
# scoped CLOUDSDK_CONFIG / KUBECONFIG / context to export. Tear down with
# gke-down.sh when finished (the cluster bills until you do).
#
# Usage:
#   gke-up.sh --credentials <key.json> --subnets <N> [options]
# Options mirror gke-sweep.sh: --cluster --zone --leaf-machine --agg-machine
#   --workers-machine --project --on-demand

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cloud/gke-lib.sh
source "$SCRIPT_DIR/gke-lib.sh"

CREDENTIALS="${GKE_CREDENTIALS:-}"; SUBNETS=""; SPOT=1
: "${GKE_CLUSTER:=leanstart-sweep}"
while [ $# -gt 0 ]; do
  case "$1" in
    --credentials)     CREDENTIALS="$2"; shift 2 ;;
    --subnets)         SUBNETS="$2"; shift 2 ;;
    --cluster)         GKE_CLUSTER="$2"; shift 2 ;;
    --zone)            GKE_ZONE="$2"; shift 2 ;;
    --leaf-machine)    GKE_LEAF_MACHINE="$2"; shift 2 ;;
    --agg-machine)     GKE_AGG_MACHINE="$2"; shift 2 ;;
    --workers-machine) GKE_WORKERS_MACHINE="$2"; shift 2 ;;
    --project)         GKE_PROJECT="$2"; shift 2 ;;
    --on-demand)       SPOT=0; shift ;;
    -h|--help)         sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) gke::err "unknown arg: $1"; exit 1 ;;
  esac
done
[ -n "$CREDENTIALS" ] || { gke::err "--credentials is required"; exit 1; }
[ -n "$SUBNETS" ] || { gke::err "--subnets is required"; exit 1; }
case "$SUBNETS" in (*[!0-9]*|"") gke::err "--subnets must be a positive integer"; exit 1 ;; esac

gke::auth "$CREDENTIALS"
CTX="$(gke::cluster_up "$GKE_CLUSTER" "$SUBNETS" "$SPOT")"

# Keep the scoped config around so the user can drive kubectl/leanstart against
# the cluster — print how to reuse it. (gke-sweep.sh wipes it automatically.)
trap - EXIT
cat >&2 <<EOF

Cluster '$GKE_CLUSTER' is up. To use it from this shell:

  export CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG"
  export KUBECONFIG="$KUBECONFIG"
  leanstart run ream:5 --subnets $SUBNETS \\
      --aggregator-hosts $(gke::agg_hosts "$SUBNETS") \\
      --skip-kind --context $CTX

Tear down when done (cluster bills until then):
  gke-down.sh --credentials $CREDENTIALS --cluster $GKE_CLUSTER --zone $GKE_ZONE
EOF
printf '%s\n' "$CTX"
