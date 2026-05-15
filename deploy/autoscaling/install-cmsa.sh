#!/usr/bin/env bash
# =============================================================================
# install-cmsa.sh — installs the Custom Metrics Stackdriver Adapter (CMSA)
# so HPA can read vllm:num_requests_waiting from Managed Prometheus.
# Run once per cluster.
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?set PROJECT_ID in your environment}"

echo ">>> Granting GMP→CMSA bridge IAM role…"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[custom-metrics/custom-metrics-stackdriver-adapter]" \
  --role="roles/monitoring.viewer" \
  --condition=None

echo ">>> Installing the adapter…"
kubectl apply -f \
  https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml

echo ">>> Annotating its SA for Workload Identity…"
kubectl annotate sa -n custom-metrics custom-metrics-stackdriver-adapter \
  iam.gke.io/gcp-service-account="${PROJECT_ID}.svc.id.goog[custom-metrics/custom-metrics-stackdriver-adapter]" \
  --overwrite

echo ">>> Waiting for adapter to become ready…"
kubectl -n custom-metrics rollout status deploy/custom-metrics-stackdriver-adapter --timeout=300s

echo ">>> Sanity check — list available custom metrics:"
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta2" | jq -r '.resources[].name' | grep -i vllm || \
  echo "    (none yet — they appear once vLLM pods are running and scraped)"
