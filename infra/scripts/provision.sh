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
: "${MACHINE_TYPES:?MACHINE_TYPES must be set in .env (e.g. g4-standard-48,g4-standard-96)}"
: "${PROVISIONING_MODE:?PROVISIONING_MODE must be set in .env}"
: "${HF_TOKEN:?HF_TOKEN must be set in .env}"

# MAX_NODES_DEFAULT has a fallback; MAX_NODES_PER_POOL is optional.
MAX_NODES_DEFAULT="${MAX_NODES_DEFAULT:-1}"
MAX_NODES_PER_POOL="${MAX_NODES_PER_POOL:-}"

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
echo "    machine types:  ${MACHINE_TYPES}"
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

# --- 2. Build the GPU nodepool table from .env ------------------------------
#
# G4 family — all NVIDIA RTX PRO 6000 Blackwell (96 GB per GPU).
# Map: machine_type -> gpu_count
#
declare -A G4_GPU_COUNT=(
  ["g4-standard-48"]=1
  ["g4-standard-96"]=2
  ["g4-standard-192"]=4
  ["g4-standard-384"]=8
)

GPU_ACCELERATOR_TYPE="nvidia-rtx-pro-6000"

# Parse MAX_NODES_PER_POOL into an associative array.
declare -A MAX_NODES_LOOKUP
if [[ -n "${MAX_NODES_PER_POOL}" ]]; then
  IFS=',' read -ra _ENTRIES <<< "${MAX_NODES_PER_POOL}"
  for ENTRY in "${_ENTRIES[@]}"; do
    ENTRY="${ENTRY// /}"  # strip whitespace
    [[ -z "${ENTRY}" ]] && continue
    IFS=':' read -r _MT _MAX <<< "${ENTRY}"
    [[ -n "${_MT}" && -n "${_MAX}" ]] || die "Invalid MAX_NODES_PER_POOL entry: ${ENTRY} (expected machine-type:max)"
    [[ "${_MAX}" =~ ^[0-9]+$ ]] || die "Invalid max-nodes value in MAX_NODES_PER_POOL: ${_MAX}"
    MAX_NODES_LOOKUP["${_MT}"]="${_MAX}"
  done
fi

# Build the nodepool list from MACHINE_TYPES.
# Format per row: <pool_name>:<machine_type>:<gpu_count>:<min>:<max>
NODEPOOLS=()
IFS=',' read -ra _SELECTED <<< "${MACHINE_TYPES}"
for MT in "${_SELECTED[@]}"; do
  MT="${MT// /}"  # strip whitespace
  [[ -z "${MT}" ]] && continue

  # Validate machine type is a known G4.
  if [[ -z "${G4_GPU_COUNT[${MT}]:-}" ]]; then
    die "Unknown machine type: ${MT}. Supported: ${!G4_GPU_COUNT[*]}"
  fi
  GPU_COUNT="${G4_GPU_COUNT[${MT}]}"

  # Resolve max nodes for this pool.
  MAX="${MAX_NODES_LOOKUP[${MT}]:-${MAX_NODES_DEFAULT}}"
  (( MAX >= 1 )) || die "max-nodes for ${MT} must be >= 1; got ${MAX}"

  # Pool name = the GPU count, e.g. "g4-1gpu", "g4-2gpu". Stable and benchmark-friendly.
  POOL_NAME="g4-${GPU_COUNT}gpu"

  NODEPOOLS+=("${POOL_NAME}:${MT}:${GPU_COUNT}:0:${MAX}")
done

[[ "${#NODEPOOLS[@]}" -gt 0 ]] || die "MACHINE_TYPES expanded to zero nodepools"

echo "    Resolved nodepool plan:"
for ROW in "${NODEPOOLS[@]}"; do
  IFS=':' read -r _N _M _G _MIN _MAX <<< "${ROW}"
  printf '      %-12s  %-18s  %d GPU(s)  min=%d  max=%d\n' "${_N}" "${_M}" "${_G}" "${_MIN}" "${_MAX}"
done

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
log "Creating/updating GPU nodepools (${PROVISIONING_MODE})"
for ROW in "${NODEPOOLS[@]}"; do
  IFS=':' read -r POOL_NAME MACHINE_TYPE GPU_COUNT MIN_NODES MAX_NODES <<< "${ROW}"

  if gcloud container node-pools describe "${POOL_NAME}" \
       --cluster="${CLUSTER_NAME}" --region="${REGION}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
    # Pool exists — check if max-nodes matches the desired value.
    CURRENT_MAX=$(gcloud container node-pools describe "${POOL_NAME}" \
      --cluster="${CLUSTER_NAME}" --region="${REGION}" \
      --project="${PROJECT_ID}" \
      --format='value(autoscaling.maxNodeCount)' 2>/dev/null || echo "")
    if [[ "${CURRENT_MAX}" != "${MAX_NODES}" ]]; then
      echo "    [${POOL_NAME}] exists, but max-nodes ${CURRENT_MAX} → ${MAX_NODES} — updating"
      gcloud container node-pools update "${POOL_NAME}" \
        --cluster="${CLUSTER_NAME}" --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --enable-autoscaling \
        --min-nodes="${MIN_NODES}" \
        --max-nodes="${MAX_NODES}" \
        --quiet
    else
      echo "    [${POOL_NAME}] already exists with correct max=${MAX_NODES} — skipping"
    fi
    continue
  fi

  echo "    [${POOL_NAME}] creating ${MACHINE_TYPE} with ${GPU_COUNT}× ${GPU_ACCELERATOR_TYPE} (max=${MAX_NODES})"

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
GPU type:         ${GPU_ACCELERATOR_TYPE}
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
