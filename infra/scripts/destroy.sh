#!/usr/bin/env bash
# =============================================================================
# infra/scripts/destroy.sh
#
# Tears down everything provision.sh created. Safe to run multiple times.
# Asks for confirmation unless YES=1 is set.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "ERROR: ${REPO_ROOT}/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "${REPO_ROOT}/.env"

: "${PROJECT_ID:?}"
: "${REGION:?}"
: "${CLUSTER_NAME:?}"

log() { printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }

if [[ "${YES:-0}" != "1" ]]; then
  echo "About to DELETE cluster '${CLUSTER_NAME}' in ${REGION} (project ${PROJECT_ID})"
  echo "This is irreversible. The HF token secret will also be deleted."
  read -r -p "Type the cluster name to confirm: " CONFIRM
  [[ "${CONFIRM}" == "${CLUSTER_NAME}" ]] || { echo "Cancelled."; exit 1; }
fi

# --- 1. Delete the cluster --------------------------------------------------
log "Deleting cluster ${CLUSTER_NAME} (~5 min)"
if gcloud container clusters describe "${CLUSTER_NAME}" \
     --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud container clusters delete "${CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet
else
  echo "    cluster not found — skipping"
fi

# --- 2. Delete the inference SA --------------------------------------------
log "Deleting inference service account"
SA_EMAIL="inference-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "${SA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --quiet
else
  echo "    SA not found — skipping"
fi

# --- 3. Delete the HF token secret -----------------------------------------
log "Deleting HF token secret"
if gcloud secrets describe hf-token --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud secrets delete hf-token --project="${PROJECT_ID}" --quiet
else
  echo "    secret not found — skipping"
fi

# --- 4. Check for orphans --------------------------------------------------
log "Scanning for orphaned resources"
ORPHAN_DISKS=$(gcloud compute disks list \
  --project="${PROJECT_ID}" \
  --filter="name~'gke-${CLUSTER_NAME}'" \
  --format="value(name,zone)" 2>/dev/null || true)
if [[ -n "${ORPHAN_DISKS}" ]]; then
  echo "    ! Found orphaned disks (delete manually if you're sure):"
  echo "${ORPHAN_DISKS}" | sed 's/^/      /'
else
  echo "    no orphaned disks"
fi

ORPHAN_LBS=$(gcloud compute forwarding-rules list \
  --project="${PROJECT_ID}" \
  --filter="description~'${CLUSTER_NAME}'" \
  --format="value(name,region)" 2>/dev/null || true)
if [[ -n "${ORPHAN_LBS}" ]]; then
  echo "    ! Found orphaned forwarding rules:"
  echo "${ORPHAN_LBS}" | sed 's/^/      /'
else
  echo "    no orphaned forwarding rules"
fi

log "Destroy complete"
