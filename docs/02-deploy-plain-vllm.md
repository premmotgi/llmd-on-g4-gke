# 02 — Deploy Plain vLLM (Baseline)

The reference baseline: a vLLM `Deployment` behind a `Service`, with the HF token mounted via the GCP Secret Store CSI driver. No fancy routing — round-robin from kube-proxy.

## Pick a GPU size

`deploy/plain-vllm/overlays/` has four overlays — `single-gpu`, `two-gpu`, `four-gpu`, `eight-gpu`. They differ only in:

- `nodeSelector.gpu-count` — which nodepool the pod lands on
- `resources.limits.nvidia.com/gpu` — how many GPUs the pod claims
- `TENSOR_PARALLEL_SIZE` env var — passed to vLLM

## Deploy

```bash
# Patch in your real PROJECT_ID first (the base manifest uses a placeholder).
sed -i.bak "s/PROJECT_ID/${PROJECT_ID}/g" deploy/plain-vllm/base/serviceaccount.yaml

kubectl apply -k deploy/plain-vllm/overlays/single-gpu
kubectl -n vllm-plain rollout status deploy/vllm-gemma --timeout=20m
```

The first rollout is slow because the pod downloads ~16 GB of weights from HuggingFace. Subsequent rollouts on the same node hit the disk cache and start in ~2 minutes.

Tail the logs:

```bash
kubectl -n vllm-plain logs -f deploy/vllm-gemma
```

You're looking for:

```
INFO ...  Started server process
INFO ...  Application startup complete.
INFO ...  Uvicorn running on http://0.0.0.0:8000
```

## Attach the HPA

```bash
kubectl apply -f deploy/autoscaling/hpa-plain-vllm.yaml
kubectl -n vllm-plain get hpa vllm-gemma -w
```

The `TARGETS` column should show a numeric value (not `<unknown>`) within a minute once CMSA is scraping. If you see `<unknown>` indefinitely, see Troubleshooting below.

## Smoke test

```bash
kubectl -n vllm-plain port-forward svc/vllm-gemma 8080:80 &

curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma",
    "messages": [{"role":"user","content":"Say hi in five words."}],
    "max_tokens": 32
  }' | jq
```

## Troubleshooting

- **Pod stuck `Pending` with `0/X nodes are available: 4 Insufficient nvidia.com/gpu`**: the GPU nodepool is at 0 nodes and the cluster autoscaler hasn't scaled up yet. Wait ~3 min. If it never comes up, check `kubectl describe pod` for the real reason — usually quota.

- **`HF_TOKEN: secret not found`**: the CSI driver mounts the secret as a file, but our Deployment expects an env var `HUGGING_FACE_HUB_TOKEN` from a Secret named `hf-token-synced`. Easiest fix: also create a plain k8s Secret:
  ```bash
  kubectl -n vllm-plain create secret generic hf-token-synced \
    --from-literal=hf-token="${HF_TOKEN}"
  ```

- **HPA `<unknown>` target**: CMSA isn't seeing the metric yet. Verify:
  ```bash
  kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta2" | jq -r '.resources[].name' | grep vllm
  ```
  If empty, GMP isn't scraping — check the PodMonitoring resource and make sure `monitoring_config.managed_prometheus.enabled` is true on the cluster.

Next: [03-deploy-llm-d.md](./03-deploy-llm-d.md)
