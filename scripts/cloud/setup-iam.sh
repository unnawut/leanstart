#!/usr/bin/env bash
# setup-iam.sh — one-time bootstrap of a DEDICATED least-scope service account
# for leanstart GKE sweeps, so the leanBench SA/key stays narrow.
#
# Run this with YOUR personal gcloud session (it creates an SA, grants roles,
# and downloads a key). It does NOT use the scoped sweep auth. Idempotent:
# re-running is safe (existing SA / bindings are left as-is; an existing key
# file is preserved unless --force).
#
# What it does, in project <PROJECT>:
#   1. enable container.googleapis.com
#   2. create service account <sa-name> (default: leanstart-gke)
#   3. grant it roles/container.admin (GKE cluster + node-pool lifecycle)
#   4. grant it roles/iam.serviceAccountUser on the default compute SA
#      (so GKE can attach that SA to the nodes it creates)
#   5. create a JSON key at --key-out
#   6. point repo-root .env's GKE_CREDENTIALS at the new key (unless --no-update-env)
#
# Usage:
#   scripts/cloud/setup-iam.sh [options]
# Options:
#   --project <id>      GCP project (default: GKE_PROJECT, else project_id from
#                       the current GKE_CREDENTIALS key, else gcloud config)
#   --sa-name <name>    service account id (default leanstart-gke)
#   --key-out <path>    where to write the new key JSON (default: alongside the
#                       current GKE_CREDENTIALS, named leanstart-gke-<project>.json;
#                       else repo-root leanstart-gke-credentials.json)
#   --no-update-env     don't rewrite repo-root .env
#   --force             overwrite an existing key file (creates a NEW key)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Sourced only for gke::log/err/require + .env autoload (no auth side effects).
# shellcheck source=scripts/cloud/gke-lib.sh
source "$SCRIPT_DIR/gke-lib.sh"

SA_NAME="leanstart-gke"
PROJECT="${GKE_PROJECT:-}"
KEY_OUT=""
UPDATE_ENV=1
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)        PROJECT="$2"; shift 2 ;;
    --sa-name)        SA_NAME="$2"; shift 2 ;;
    --key-out)        KEY_OUT="$2"; shift 2 ;;
    --no-update-env)  UPDATE_ENV=0; shift ;;
    --force)          FORCE=1; shift ;;
    -h|--help)        sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) gke::err "unknown arg: $1"; exit 1 ;;
  esac
done

gke::require gcloud

# --- resolve project ----------------------------------------------------------
if [ -z "$PROJECT" ] && [ -n "${GKE_CREDENTIALS:-}" ] && [ -f "${GKE_CREDENTIALS:-}" ]; then
  PROJECT="$(sed -n 's/.*"project_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GKE_CREDENTIALS" | head -1)"
fi
[ -z "$PROJECT" ] && PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[ -n "$PROJECT" ] || { gke::err "could not determine project; pass --project <id>"; exit 1; }

# --- confirm we're on a personal (user) gcloud account, not the SA ------------
ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1 || true)"
[ -n "$ACTIVE" ] || { gke::err "no active gcloud account. Run: gcloud auth login"; exit 1; }
gke::log "Project:        $PROJECT"
gke::log "Active account: $ACTIVE"
case "$ACTIVE" in
  *gserviceaccount.com)
    gke::err "active account looks like a service account ($ACTIVE)."
    gke::err "Run this with your personal account: gcloud auth login"
    exit 1 ;;
esac

SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

# --- default key-out ----------------------------------------------------------
if [ -z "$KEY_OUT" ]; then
  if [ -n "${GKE_CREDENTIALS:-}" ]; then
    KEY_OUT="$(cd "$(dirname "$GKE_CREDENTIALS")" && pwd)/leanstart-gke-${PROJECT}.json"
  else
    KEY_OUT="$REPO_ROOT/leanstart-gke-credentials.json"
  fi
fi

gke::log "Service account: $SA_EMAIL"
gke::log "Key output:      $KEY_OUT"
printf '\nProceed? [y/N] ' >&2
read -r ans
case "$ans" in [yY]|[yY][eE][sS]) ;; *) gke::log "Aborted."; exit 0 ;; esac

# --- 1. enable API ------------------------------------------------------------
gke::log "Enabling container.googleapis.com"
gcloud services enable container.googleapis.com --project "$PROJECT" >&2

# --- 2. create SA (idempotent) ------------------------------------------------
if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" >/dev/null 2>&1; then
  gke::log "Service account already exists — reusing"
else
  gke::log "Creating service account $SA_NAME"
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name "leanstart GKE sweeps" --project "$PROJECT" >&2
fi

# --- 3. grant container.admin -------------------------------------------------
gke::log "Granting roles/container.admin on project"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" --role roles/container.admin \
  --condition=None >/dev/null

# --- 4. grant serviceAccountUser on the default compute SA --------------------
PROJNUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
COMPUTE_SA="${PROJNUM}-compute@developer.gserviceaccount.com"
gke::log "Granting roles/iam.serviceAccountUser on $COMPUTE_SA"
gcloud iam service-accounts add-iam-policy-binding "$COMPUTE_SA" \
  --member "serviceAccount:${SA_EMAIL}" --role roles/iam.serviceAccountUser \
  --project "$PROJECT" >/dev/null

# --- 5. create key ------------------------------------------------------------
if [ -f "$KEY_OUT" ] && [ "$FORCE" != "1" ]; then
  gke::log "Key file already exists ($KEY_OUT) — keeping it (pass --force to mint a new one)"
else
  mkdir -p "$(dirname "$KEY_OUT")"
  gke::log "Creating key $KEY_OUT"
  gcloud iam service-accounts keys create "$KEY_OUT" --iam-account "$SA_EMAIL" >&2
  chmod 600 "$KEY_OUT"
fi

# --- 6. update .env -----------------------------------------------------------
ENV_FILE="$REPO_ROOT/.env"
if [ "$UPDATE_ENV" = "1" ]; then
  if [ -f "$ENV_FILE" ]; then cp "$ENV_FILE" "$ENV_FILE.bak"; fi
  if [ -f "$ENV_FILE" ] && grep -q '^GKE_CREDENTIALS=' "$ENV_FILE"; then
    # Replace the existing line (portable: temp file, not sed -i).
    awk -v p="$KEY_OUT" '/^GKE_CREDENTIALS=/{print "GKE_CREDENTIALS=" p; next} {print}' \
      "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    printf 'GKE_CREDENTIALS=%s\n' "$KEY_OUT" >> "$ENV_FILE"
  fi
  gke::log "Updated $ENV_FILE -> GKE_CREDENTIALS=$KEY_OUT (backup at .env.bak)"
fi

cat >&2 <<EOF

Done. The dedicated SA '$SA_EMAIL' is ready and the leanBench key is untouched.
Verify with a smoke run:
  scripts/cloud/gke-sweep.sh --clients "ream:5" --subnets 2 --keep
EOF
