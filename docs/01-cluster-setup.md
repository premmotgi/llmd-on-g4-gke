# 01 — Cluster Setup

Goal: a GKE cluster with four GPU nodepools, Workload Identity, Gateway API, and Managed Prometheus enabled. Idle cost ≈ control-plane only (~$72/month) because every GPU nodepool has `min-nodes=0`.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| `gcloud` | recent | `gcloud auth login` and `gcloud auth application-default login` first |
| `kubectl` | matching cluster | gke-gcloud-auth-plugin too |
| `helm` | ≥ 3.10 | |
| `jq` | any | used by `provision.sh` |
| `python3` | ≥ 3.11 | for the report builder + llm-d-benchmark |

You also need:

- **GPU quota** in your region for the family you chose. Check with:
  ```bash
  gcloud compute regions describe ${REGION} \
    --format="value(quotas[].metric,quotas[].limit,quotas[].usage)" \
    | grep -i gpu
  ```
  G4 quota is currently scarce; if the default project quota is 0, file a quota increase or set `PROVISIONING_MODE=flex-start` to ride the DWS queue.

- **HuggingFace access** to `google/gemma-4-E4B-it`. Visit the model card while logged in and accept the license. Create a read-token at https://huggingface.co/settings/tokens.

## Run

```bash
# 1) Configure
cp .env.example .env
$EDITOR .env                  # set PROJECT_ID, REGION, HF_TOKEN, GPU_FAMILY, PROVISIONING_MODE

# 2) Provision
bash infra/scripts/provision.sh
```

The script is idempotent — it checks for each resource (cluster, nodepools, SA, secret) before creating, so re-running it after a failure or a config tweak is safe.

Total time: ~10 min. Breakdown:
- APIs enable: instant if already enabled
- Cluster control plane: ~6 min
- 4 GPU nodepools in sequence at `min-nodes=0`: ~1 min each
- SA + IAM bindings + HF token push: ~10 s

## Verify

```bash
kubectl get nodes -L cloud.google.com/gke-accelerator
# Only the 2 system nodes should be Ready. GPU nodepools are at 0.

kubectl get gatewayclass
# Should include gke-l7-rilb (the GKE Inference Gateway class).

gcloud secrets list --project="${PROJECT_ID}"
# Should include hf-token.
```

## Wire up the Custom Metrics Stackdriver Adapter

HPA needs CMSA to read `vllm:num_requests_waiting` from Managed Prometheus.

```bash
bash deploy/autoscaling/install-cmsa.sh
```

## Common issues

- **`Error 403: Insufficient quota`** during nodepool creation: the GPU quota in your region is 0. Either file a quota-increase request in the Google Cloud Console (IAM & Admin → Quotas, filter by your region + `NVIDIA_RTX_PRO_6000_GPUS` / `NVIDIA_L4_GPUS`), or set `PROVISIONING_MODE=flex-start` in `.env` and re-run `provision.sh` — Dynamic Workload Scheduler doesn't need standing quota.

- **`gke-l7-rilb` GatewayClass missing**: GKE only creates this when the cluster has `--gateway-api=standard`. If `provision.sh` skipped cluster creation because one already existed without that flag, enable it manually:
  ```bash
  gcloud container clusters update "${CLUSTER_NAME}" \
    --region="${REGION}" --gateway-api=standard
  ```

- **`provision.sh` says "active account" is wrong**: switch with `gcloud config set account my@example.com` then re-run.

- **Re-running on a partial failure**: just re-run `bash infra/scripts/provision.sh`. Every step is `describe || create`, so existing resources are skipped.

Next: [02-deploy-plain-vllm.md](./02-deploy-plain-vllm.md)
