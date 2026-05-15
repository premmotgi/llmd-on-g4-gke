#!/usr/bin/env bash
# =============================================================================
# infra/scripts/provision.sh
#
# Provisions GKE cluster + GPU nodepools + IAM + Secret Manager for the POC.
#
# Idempotent — safe to re-run. Each step checks if the resource exists first
# and skips or updates accordingly.
#
# Reads config from ../../.env at the repo root.
# =============================================================================
set -euo pipefail

# --- Load env ---------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "ERROR: ${REPO_ROOT}/.env not found. Copy .env.example to .env and edit it." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "${REPO_ROOT}/.env"

: "${PROJECT_ID:?PROJECT_ID must be set in .env}"
: "${REGION:?REGION must be set in .env}"
: "${CLUSTER_NAME:?CLUSTER_NAME must be set in .env}"
: "${GPU_FAMILY:?GPU_FAMILY must be set in .env (g4 or g2)}"
: "${PROVISIONING_MODE:?PROVISIONING_MODE must be set in .env}"
: "${HF_TOKEN:?HF_TOKEN must be set in .env}"

# --- Helpers ----------------------------------------------------------------
log()  { printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mXXX %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for cmd in gcloud kubectl jq; do require_cmd "$cmd"; done

# --- Sanity check the gcloud config -----------------------------------------
log "Verifying gcloud auth + project"
gcloud config set project "${PROJECT_ID}" --quiet
ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
[[ -n "${ACTIVE_ACCOUNT}" ]] || die "No active gcloud account. Run: gcloud auth login"
echo "    active account: ${ACTIVE_ACCOUNT}"
echo "    project:        ${PROJECT_ID}"
echo "    region:         ${REGION}"
echo "    GPU family:     ${GPU_FAMILY}"
echo "    provisioning:   ${PROVISIONING_MODE}"

# --- 1. Enable APIs ---------------------------------------------------------
log "Enabling required GCP APIs (may take a minute)"
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  --project="${PROJECT_ID}"

# --- 2. Resolve GPU nodepool table per family -------------------------------
#
# Format per row: <pool_name>:<machine_type>:<gpu_count>:<min>:<max>
#
if [[ "${GPU_FAMILY}" == "g4" ]]; then
  GPU_ACCELERATOR_TYPE="nvidia-rtx-pro-6000"
  NODEPOOLS=(
    "g4-1gpu:g4-standard-48:1:0:4"
    "g4-2gpu:g4-standard-96:2:0:2"
    "g4-4gpu:g4-standard-192:4:0:1"
    "g4-8gpu:g4-standard-384:8:0:1"
  )
elif [[ "${GPU_FAMILY}" == "g2" ]]; then
  GPU_ACCELERATOR_TYPE="nvidia-l4"
  NODEPOOLS=(
    "g2-1gpu-small:g2-standard-4:1:0:4"
    "g2-1gpu-mid:g2-standard-12:1:0:4"
    "g2-2gpu:g2-standard-24:2:0:2"
    "g2-4gpu:g2-standard-48:4:0:1"
  )
else
  die "GPU_FAMILY must be g4 or g2; got: ${GPU_FAMILY}"
fi

# --- 3. Create the cluster (if it doesn't exist) ----------------------------
log "Checking for cluster ${CLUSTER_NAME} in ${REGION}"
if gcloud container clusters describe "${CLUSTER_NAME}" \
     --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    cluster already exists — skipping create"
else
  log "Creating GKE cluster (this takes ~6-8 min)"
  gcloud container clusters create "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --release-channel=regular \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --gateway-api=standard \
    --enable-managed-prometheus \
    --enable-secret-manager \
    --autoscaling-profile=optimize-utilization \
    --machine-type=e2-standard-4 \
    --num-nodes=2 \
    --no-enable-basic-auth \
    --no-issue-client-certificate \
    --enable-ip-alias \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM,POD,DEPLOYMENT
fi

# --- 4. Get kubectl credentials ---------------------------------------------
log "Fetching kubeconfig"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region="${REGION}" --project="${PROJECT_ID}"

# --- 5. Create GPU nodepools -----------------------------------------------
#
# Each nodepool has min=0 so idle cost = $0 for GPUs. The cluster autoscaler
# brings them up on demand. Spot / Flex-Start / on-demand flags differ per mode.
#
log "Creating GPU nodepools (${GPU_FAMILY}, ${PROVISIONING_MODE})"
for ROW in "${NODEPOOLS[@]}"; do
  IFS=':' read -r POOL_NAME MACHINE_TYPE GPU_COUNT MIN_NODES MAX_NODES <<< "${ROW}"

  if gcloud container node-pools describe "${POOL_NAME}" \
       --cluster="${CLUSTER_NAME}" --region="${REGION}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "    [${POOL_NAME}] already exists — skipping"
    continue
  fi

  echo "    [${POOL_NAME}] creating ${MACHINE_TYPE} with ${GPU_COUNT}× ${GPU_ACCELERATOR_TYPE}"

  # Build per-mode flags. Spot and Flex-Start are mutually exclusive.
  PROVISIONING_FLAGS=()
  case "${PROVISIONING_MODE}" in
    on-demand)
      :
      ;;
    spot)
      PROVISIONING_FLAGS+=("--spot")
      ;;
    flex-start)
      PROVISIONING_FLAGS+=(
        "--enable-queued-provisioning"
        "--reservation-affinity=none"
        "--no-enable-autorepair"
      )
      ;;
    *)
      die "Unknown PROVISIONING_MODE: ${PROVISIONING_MODE}"
      ;;
  esac

  gcloud container node-pools create "${POOL_NAME}" \
    --cluster="${CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --machine-type="${MACHINE_TYPE}" \
    --accelerator="type=${GPU_ACCELERATOR_TYPE},count=${GPU_COUNT},gpu-driver-version=latest" \
    --num-nodes=0 \
    --enable-autoscaling \
    --min-nodes="${MIN_NODES}" \
    --max-nodes="${MAX_NODES}" \
    --location-policy=ANY \
    --disk-type=pd-ssd \
    --disk-size=200 \
    --image-type=COS_CONTAINERD \
    --workload-metadata=GKE_METADATA \
    --node-labels="workload=llm-inference,gpu-count=${GPU_COUNT},machine-type=${MACHINE_TYPE},provisioning-mode=${PROVISIONING_MODE}" \
    --node-taints="nvidia.com/gpu=present:NoSchedule" \
    --scopes="https://www.googleapis.com/auth/cloud-platform" \
    "${PROVISIONING_FLAGS[@]}"
done

# --- 6. Workload Identity service account -----------------------------------
log "Setting up Workload Identity"
SA_NAME="inference-runtime"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    SA already exists — skipping create"
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="vLLM + llm-d runtime SA" \
    --project="${PROJECT_ID}"
fi

# Allow the KSAs (which we'll create when deploying) to impersonate the GSA.
for NS_KSA in "vllm-plain/vllm" "llm-d/llm-d"; do
  echo "    binding workloadIdentityUser → ${NS_KSA}"
  gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NS_KSA}]" \
    --condition=None \
    --quiet >/dev/null
done

# --- 7. HuggingFace token in Secret Manager --------------------------------
log "Pushing HF token to Secret Manager"
if gcloud secrets describe hf-token --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    secret 'hf-token' exists — adding a new version"
else
  gcloud secrets create hf-token \
    --replication-policy=automatic \
    --project="${PROJECT_ID}"
fi

# Add a new version (always — the user may have rotated the token).
printf '%s' "${HF_TOKEN}" | \
  gcloud secrets versions add hf-token \
    --project="${PROJECT_ID}" \
    --data-file=-

# Grant the inference SA read access.
gcloud secrets add-iam-policy-binding hf-token \
  --project="${PROJECT_ID}" \
  --role="roles/secretmanager.secretAccessor" \
  --member="serviceAccount:${SA_EMAIL}" \
  --condition=None \
  --quiet >/dev/null

# --- 8. Summary -------------------------------------------------------------
log "Provisioning complete"
cat <<EOF

Cluster:          ${CLUSTER_NAME}
Region:           ${REGION}
Inference SA:     ${SA_EMAIL}
GPU family:       ${GPU_FAMILY} (${GPU_ACCELERATOR_TYPE})
Provisioning:     ${PROVISIONING_MODE}
GPU nodepools:    $(printf '%s\n' "${NODEPOOLS[@]}" | cut -d: -f1 | tr '\n' ' ')

Next steps:
  bash deploy/llm-d/00-prereqs.sh        # CRDs + Helm repos + hf-token Secret
  bash deploy/autoscaling/install-cmsa.sh # custom-metrics adapter for HPA
  make deploy-plain                       # deploy plain vLLM baseline
  make deploy-llmd                        # deploy llm-d

Then:
  bash benchmark/scripts/run-sweep.sh     # full benchmark sweep

EOF
