#!/usr/bin/env bash
# =============================================================================
# 00-prereqs.sh — install everything llm-d needs on GKE before its own charts.
#
# What this installs:
#   1. Gateway API v1.4.0 CRDs (Service-mesh's Service/Gateway/HTTPRoute/etc.)
#   2. Gateway API Inference Extension v1.4.0 CRDs (InferencePool, InferenceObjective)
#   3. The GKE Inference Gateway controller (uses gke-l7-rilb-mc gateway class)
#   4. kube-prometheus-stack (for local Prometheus + Grafana — optional;
#      GKE Managed Prometheus is also doing scraping in parallel)
#   5. The Helm repos for llm-d-infra and llm-d-modelservice
#
# Idempotent — safe to re-run.
# =============================================================================
set -euo pipefail

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
INFERENCE_EXT_VERSION="${INFERENCE_EXT_VERSION:-v1.4.0}"

echo ">>> 1/5  Gateway API ${GATEWAY_API_VERSION} CRDs"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ">>> 2/5  Gateway API Inference Extension ${INFERENCE_EXT_VERSION} CRDs"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${INFERENCE_EXT_VERSION}/manifests.yaml"

echo ">>> 3/5  Ensuring 'gke-l7-rilb' GatewayClass is registered (GKE Inference Gateway)"
# This GatewayClass ships with GKE when the gateway_api_config block is set
# in provision.sh (via `--gateway-api=standard`). We just verify here.
kubectl get gatewayclass gke-l7-rilb >/dev/null 2>&1 || {
  echo "    ! gke-l7-rilb not found. Re-run infra/scripts/provision.sh." >&2
  exit 1
}

echo ">>> 4/5  Helm repos"
helm repo add llm-d-infra        https://llm-d-incubation.github.io/llm-d-infra/        || true
helm repo add llm-d-modelservice https://llm-d-incubation.github.io/llm-d-modelservice/ || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts   || true
helm repo update

echo ">>> 5/5  Namespace + HF token Secret"
kubectl create ns llm-d --dry-run=client -o yaml | kubectl apply -f -

# llm-d expects a Secret named llm-d-hf-token with key HF_TOKEN.
if [[ -n "${HF_TOKEN:-}" ]]; then
  kubectl -n llm-d create secret generic llm-d-hf-token \
    --from-literal=HF_TOKEN="${HF_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "    ! HF_TOKEN not set — create the Secret manually:"
  echo "      kubectl -n llm-d create secret generic llm-d-hf-token --from-literal=HF_TOKEN=hf_..."
fi

echo ">>> Done. Now run:"
echo "    helm install llm-d-infra llm-d-infra/llm-d-infra \\"
echo "      -n llm-d -f deploy/llm-d/values-infra.yaml"
echo "    helm install gemma llm-d-modelservice/llm-d-modelservice \\"
echo "      -n llm-d -f deploy/llm-d/values-modelservice-gemma4.yaml"
