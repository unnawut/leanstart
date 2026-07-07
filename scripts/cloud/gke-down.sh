#!/usr/bin/env bash
# gke-down.sh — delete a leanstart sweep cluster. Safe to run any time as a
# cost safety-net (e.g. if a sweep crashed before its teardown). Idempotent:
# a missing cluster is treated as success.
#
# Usage:
#   gke-down.sh --credentials <key.json> [--cluster <name>] [--zone <zone>]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cloud/gke-lib.sh
source "$SCRIPT_DIR/gke-lib.sh"

CREDENTIALS="${GKE_CREDENTIALS:-}"; IDLE=0
: "${GKE_CLUSTER:=leanstart-sweep}"
while [ $# -gt 0 ]; do
  case "$1" in
    --credentials) CREDENTIALS="$2"; shift 2 ;;
    --cluster)     GKE_CLUSTER="$2"; shift 2 ;;
    --zone)        GKE_ZONE="$2"; shift 2 ;;
    --project)     GKE_PROJECT="$2"; shift 2 ;;
    --idle)        IDLE=1; shift ;;
    -h|--help)     sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) gke::err "unknown arg: $1"; exit 1 ;;
  esac
done
[ -n "$CREDENTIALS" ] || { gke::err "--credentials is required"; exit 1; }

gke::auth "$CREDENTIALS"
if [ "$IDLE" = "1" ]; then
  # Scale node pools to 0 but keep the cluster (free control plane + metrics
  # stack persist). Cheapest way to park a reusable sweep cluster. The down path
  # loops all aggregator pools, so the subnet count argument is unused.
  gke::scale_pools "$GKE_CLUSTER" 0 down
else
  gke::cluster_down "$GKE_CLUSTER"
fi
gke::log "Done."
