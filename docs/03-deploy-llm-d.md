# 03 — Deploy llm-d

llm-d v0.7's "Optimized Baseline" — vLLM behind the Gateway API Inference Extension with a prefix-cache-aware Endpoint Picker Plugin (EPP).

## What gets deployed

| Helm release | Chart | Role |
|---|---|---|
| `llm-d-infra` | `llm-d-infra/llm-d-infra` | Gateway resource, EPP, PodMonitor scaffolding |
| `gemma` | `llm-d-modelservice/llm-d-modelservice` | Decode (and optional prefill) Deployments for Gemma, the InferencePool, and the HTTPRoute |

## Install

```bash
source .env
bash deploy/llm-d/00-prereqs.sh    # CRDs, repos, hf-token Secret

helm install llm-d-infra llm-d-infra/llm-d-infra \
  -n llm-d -f deploy/llm-d/values-infra.yaml

helm install gemma llm-d-modelservice/llm-d-modelservice \
  -n llm-d -f deploy/llm-d/values-modelservice-gemma4.yaml
```

## Verify

```bash
helm -n llm-d list
# NAME           STATUS     CHART                         APP VERSION
# llm-d-infra    deployed   llm-d-infra-v1.4.0            v0.7.0
# gemma          deployed   llm-d-modelservice-v0.4.9     v0.7.0

kubectl -n llm-d get all
# You should see:
#   pod/llm-d-infra-epp-...    Running   (the smart router)
#   pod/gemma-decode-...       Running   (vLLM)
#   gateway/llm-d-infra-gateway  ...PROGRAMMED   True
#   inferencepool/gemma         (status Ready)
```

## Attach the HPA

```bash
kubectl apply -f deploy/autoscaling/hpa-llm-d.yaml
```

## Smoke test through the Gateway

```bash
GATEWAY_IP=$(kubectl -n llm-d get gateway llm-d-infra-gateway \
  -o jsonpath='{.status.addresses[0].value}')

curl -s "http://${GATEWAY_IP}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma",
    "messages": [{"role":"user","content":"Say hi in five words."}],
    "max_tokens": 32
  }' | jq
```

## Swapping to multi-GPU nodes

Sweep across machine sizes by layering a values file on top of the base:

```bash
# 2 replicas on a 2-GPU node:
helm upgrade gemma llm-d-modelservice/llm-d-modelservice -n llm-d \
  -f deploy/llm-d/values-modelservice-gemma4.yaml \
  -f deploy/llm-d/values-modelservice-gemma4-2gpu.yaml

# 4 replicas on a 4-GPU node:
helm upgrade gemma llm-d-modelservice/llm-d-modelservice -n llm-d \
  -f deploy/llm-d/values-modelservice-gemma4.yaml \
  -f deploy/llm-d/values-modelservice-gemma4-4gpu.yaml

# 8 replicas on an 8-GPU node:
helm upgrade gemma llm-d-modelservice/llm-d-modelservice -n llm-d \
  -f deploy/llm-d/values-modelservice-gemma4.yaml \
  -f deploy/llm-d/values-modelservice-gemma4-8gpu.yaml
```

The benchmark sweep script does this for you.

## When to enable Prefill/Decode disaggregation

For Gemma 4 E4B (~8B total params), P/D disaggregation usually **isn't worth it**. The model is small enough that prefill is fast and the coordination overhead between prefill and decode pods eats the win.

P/D shines when you have:
- Very long input contexts (16k+) where prefill dominates wall-clock time
- Strict TTFT SLAs you can't hit by scaling decode pods
- A model big enough that prefill needs different parallelism than decode

If you want to try it anyway, set `prefill.enabled: true` and `prefill.replicas: N` in the modelservice values file.

## Troubleshooting

- **Gateway `ADDRESS` is `<none>`**: GKE needs ~1–2 min after the Gateway is created to provision an L7 LB. Watch `kubectl describe gateway llm-d-infra-gateway -n llm-d`.

- **EPP pod CrashLoopBackOff with `failed to discover InferencePool`**: the InferencePool resource hasn't been created yet, or the EPP config points at the wrong name. Check `kubectl -n llm-d get inferencepool` matches what `values-infra.yaml` expects.

- **`HF_TOKEN` rejected**: you need to accept the Gemma license on HuggingFace with the same account whose token you're using. Visit the model card while logged in.

Next: [04-autoscaling.md](./04-autoscaling.md)
