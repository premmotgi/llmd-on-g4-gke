# Dashboards

Two predefined dashboards in Cloud Monitoring once GMP is scraping the workloads:

1. **vLLM** — https://console.cloud.google.com/monitoring/dashboards/integration/vllm
   - Request rate, TTFT, TPOT, queue depth, KV cache utilization
   - One panel per replica; aggregate at the top

2. **GKE Inference Gateway** — https://console.cloud.google.com/monitoring/dashboards/integration/gke-inference-gateway
   - Routing decisions, EPP latency, prefix-cache hit rate, pool health
   - llm-d-specific; doesn't show up for plain-vllm

For local Grafana (e.g. when running the benchmark from your laptop and you
don't want to leave the Cloud Console open), use:

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f benchmark/dashboards/kube-prometheus-stack-values.yaml

kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# user: admin / pass: prom-operator (override in values)
```

Then import the JSON dashboards from the llm-d repo:

- https://raw.githubusercontent.com/llm-d/llm-d/main/charts/llm-d/dashboards/llm-d-overview.json
- https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/main/config/manifests/gateway/dashboard.json
