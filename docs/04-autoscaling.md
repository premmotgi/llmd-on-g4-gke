# 04 — Autoscaling

Three independent autoscalers cooperate here. Knowing which one fires when is essential to interpreting the benchmark.

## The three layers

```
                ┌──────────────────────────────────────┐
   Load surge → │ HPA (per Deployment)                 │
                │   metric: vllm:num_requests_waiting  │
                │   action: add replicas               │
                └──────────────────┬───────────────────┘
                                   │ new replica Pending
                                   ▼
                ┌──────────────────────────────────────┐
                │ Cluster Autoscaler (per nodepool)    │
                │   trigger: unschedulable Pod with    │
                │            nvidia.com/gpu request    │
                │   action: scale nodepool +1 node     │
                └──────────────────┬───────────────────┘
                                   │ new node Ready
                                   ▼
                ┌──────────────────────────────────────┐
                │ vLLM in-pod batcher                  │
                │   action: pack incoming requests     │
                │           into a continuous batch    │
                └──────────────────────────────────────┘
```

## Why not just use GPU utilization?

GPU util is the classic HPA signal and it's **wrong for LLM inference**. vLLM can pin a GPU at 99% with one slow request or with 50 concurrent fast ones — same number, very different latency. The right signal is **queue depth** (`vllm:num_requests_waiting`), which is exactly proportional to user-visible latency degradation.

This is also the signal that the GKE Inference Gateway and llm-d's EPP use internally for routing. Using it for autoscaling means HPA and EPP agree on what "loaded" means.

## Tuning the HPA

The two files in `deploy/autoscaling/` are minimal — tune these knobs:

| Knob | Default | Notes |
|---|---|---|
| `averageValue` | `10` | Higher = more queueing = more latency, fewer pods. Tune by SLA. |
| `scaleUp.stabilizationWindowSeconds` | `30` | Faster reaction = costlier overshoot. 30s is aggressive; pick 60s for steadier patterns. |
| `scaleDown.stabilizationWindowSeconds` | `300` | Conservative — avoid flapping. Don't go below 5 min for LLM workloads; pod cold-start is ~2 min. |
| `maxReplicas` | `8` | Caps your blast radius. Should match the GPU quota you have available. |

## What the benchmark measures

`benchmark/scenarios/autoscale-burst.yaml.j2` deliberately ramps load from 4 → 64 concurrent users over 30 seconds. It records:

- **time_to_new_replica_ready_s** — HPA decision + pod schedule + pull image + load weights. Expect ~120s with cold cache, ~30s with weights already on the node.
- **time_to_new_node_ready_s** — cluster autoscaler decision + node provision + nvidia driver install + node Ready. Expect ~3–5 min on G4/G2.
- **SLA hold rate during the burst** — percentage of requests in the burst phase that stayed under your TTFT/TPOT targets. This is the metric customers care about.

## Image preloading — the single biggest cold-start win

The dominant cost on a new replica is **pulling the vLLM container image (~5 GB)** and **loading the model weights into VRAM (~30 s for an 8B model)**. You can pre-pull the image with a DaemonSet, but for the POC the cleanest fix is GKE's image streaming + secondary boot disk for the model weights.

This isn't enabled in the POC by default to keep the provisioning script readable, but for production:

1. Build a custom node image (or use a secondary disk) with the vLLM image and weights baked in.
2. Set `gcfs_config { enabled = true }` on the nodepool for image streaming.
3. Time-to-new-replica drops from ~2 min to ~20s.

## Multi-pool gotcha

You have four GPU nodepools. The cluster autoscaler picks one based on pod resource requests and node selectors. **If your overlay picks a `nodeSelector` that doesn't match any nodepool, the pod stays Pending forever.** Double-check the `gpu-count` label values match the `--node-labels` set by `provision.sh` exactly.

Next: [05-benchmark.md](./05-benchmark.md)
