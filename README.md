# Gemma on GKE — Plain vLLM vs llm-d POC

End-to-end POC for serving **Gemma 4 E4B-it** on **Google Kubernetes Engine (GKE)** with autoscaling, comparing two serving stacks side-by-side:

1. **Plain vLLM** — a single vLLM Deployment behind a Service + HPA.
2. **llm-d** — the CNCF Sandbox distributed inference stack (vLLM under intelligent routing, KV-cache-aware load balancing, optional prefill/decode disaggregation).

You will provision a GKE cluster with four GPU nodepools (a range of sizes from 1 GPU up to 8 GPUs per node), deploy both stacks, drive load against them with the official `llm-d-benchmark` harness, and produce a side-by-side comparison report.

---

## ⚠️ Before you start — please confirm these assumptions

Your brief had a few items that need a quick check before we burn GPU quota. Read these and tell me if anything needs to change.

### 1. Model — defaulting to `google/gemma-4-E4B-it`

You wrote `google/gemma-4-E4B-it`. Two models match closely:

| Candidate | Released | Status |
|---|---|---|
| `google/gemma-4-E4B-it` | March 31, 2026 | **Default in this repo.** Gemma 4 dense, ~4.5B effective / ~8B total params, 128K context, multimodal (text/image/audio). vLLM has a [first-party recipe](https://docs.vllm.ai/projects/recipes/en/latest/Google/Gemma4.html). |
| `google/gemma-3n-E4B-it` | June 2025 | Older Gemma 3n MatFormer model. Same `E4B` naming. Had early vLLM integration friction; works on recent vLLM. |

The repo defaults to **`google/gemma-4-E4B-it`**. If you actually meant 3n, change `MODEL_ID` in `.env` — every manifest reads from that one place.

### 2. GPU machine types — `g4-standard-{48,24,12,6}` doesn't fully exist

The `g4-standard-*` series on GCP is **NVIDIA RTX PRO 6000 (Blackwell, 96 GB)**, and the **smallest size is `g4-standard-48` with 1 GPU**. There is no `g4-standard-24`, `g4-standard-12`, or `g4-standard-6`.

Two interpretations — pick one and tell me, the repo supports both:

**Option A — You meant the G4 family, scaling by GPU count** (this is the default in the repo):

| Machine type | GPUs | GPU model | vCPU | RAM |
|---|---|---|---|---|
| `g4-standard-48` | 1× | RTX PRO 6000 (96 GB) | 48 | 180 GB |
| `g4-standard-96` | 2× | RTX PRO 6000 (96 GB) | 96 | 360 GB |
| `g4-standard-192` | 4× | RTX PRO 6000 (96 GB) | 192 | 720 GB |
| `g4-standard-384` | 8× | RTX PRO 6000 (96 GB) | 384 | 1440 GB |

**Option B — You meant the G2 family (L4 GPUs)** — those sizes match your numbers exactly:

| Machine type | GPUs | GPU model | vCPU | RAM |
|---|---|---|---|---|
| `g2-standard-4`  | 1× | L4 (24 GB) | 4 | 16 GB |
| `g2-standard-12` | 1× | L4 (24 GB) | 12 | 48 GB |
| `g2-standard-24` | 2× | L4 (24 GB) | 24 | 96 GB |
| `g2-standard-48` | 4× | L4 (24 GB) | 48 | 192 GB |

For a 4B-effective-param model like Gemma 4 E4B, **even one L4 (24 GB) is plenty for BF16 weights + a healthy KV cache**, so Option B is actually the more cost-realistic POC. The benchmark story ("max throughput per chip") is more interesting on L4 than on a 96 GB Blackwell that's mostly idle.

`infra/scripts/provision.sh` has both nodepool sets — flip `GPU_FAMILY` to `g4` or `g2` in `.env`.

### 3. Provisioning model — three modes available

Your brief listed Flex / Spot / On-demand. The repo supports all three via `PROVISIONING_MODE` in `.env`:

- `on-demand` — standard, predictable pricing, no preemption. Default.
- `spot` — up to 91% cheaper, can be preempted. Great for benchmarks if you accept restarts.
- `flex-start` — [Flex-Start provisioning](https://cloud.google.com/blog/products/compute/introducing-dynamic-workload-scheduler) (queued provisioning via Dynamic Workload Scheduler). Best for grabbing scarce H100/Blackwell quota.

---

## Repo layout

```
gke-gemma-poc/
├── .env.example                  # one place to set MODEL_ID, REGION, project, HF token
├── README.md                     # you are here
├── infra/
│   └── scripts/                  # provision.sh + destroy.sh — GKE cluster, 4 GPU nodepools, IAM, Workload Identity
├── deploy/
│   ├── plain-vllm/               # vLLM Deployment + Service + HPA (baseline)
│   ├── llm-d/                    # llm-d-infra + modelservice Helm values for Gemma 4
│   └── autoscaling/              # CMSA / custom-metrics HPA configs (shared)
├── benchmark/
│   ├── scenarios/                # llm-d-benchmark DOE scenarios (sweep over machine types)
│   ├── scripts/                  # one-shot wrappers around llm-d-benchmark + vllm bench serve
│   └── dashboards/               # Cloud Monitoring + Grafana JSON for vLLM + Inference Gateway
└── docs/
    ├── 01-cluster-setup.md
    ├── 02-deploy-plain-vllm.md
    ├── 03-deploy-llm-d.md
    ├── 04-autoscaling.md
    ├── 05-benchmark.md
    ├── 06-results-interpretation.md
    └── 07-cleanup.md
```

---

## End-to-end run, top to bottom

```bash
# 0. Configure
cp .env.example .env
$EDITOR .env                       # set PROJECT_ID, REGION, HF_TOKEN, GPU_FAMILY, etc.

# 1. Provision GKE + GPU nodepools (~10 min)
bash infra/scripts/provision.sh

# 2. (kubeconfig was already fetched by provision.sh — confirm)
kubectl get nodes

# 3. Install Gateway API + the GKE Inference Gateway controller
bash deploy/llm-d/00-prereqs.sh
bash deploy/autoscaling/install-cmsa.sh

# 4. Deploy plain vLLM (baseline) on the 1-GPU nodepool
kubectl apply -k deploy/plain-vllm/overlays/single-gpu

# 5. Deploy llm-d on the same nodepool
helm install llm-d-infra llm-d-infra/llm-d-infra \
  -n llm-d -f deploy/llm-d/values-infra.yaml
helm install gemma llm-d-modelservice/llm-d-modelservice \
  -n llm-d -f deploy/llm-d/values-modelservice-gemma4.yaml

# 6. Run the benchmark sweep
bash benchmark/scripts/run-sweep.sh

# 7. Open the comparison report
open benchmark/results/<timestamp>/comparison-report.html

# 8. Tear it all down when you're done
bash benchmark/scripts/teardown.sh
```

Each step has a dedicated doc under `docs/` with the actual gcloud / kubectl / helm commands, troubleshooting, and "what to look for" notes.

---

## What you're measuring

For each `(machine_type, serving_stack)` cell in the sweep, the benchmark records:

- **Per-request:** TTFT p50/p90/p99, TPOT p50/p90/p99, end-to-end latency
- **Aggregate:** request throughput (req/s), output token throughput (tok/s)
- **Cluster:** GPU utilization, KV cache hit rate (llm-d only), HPA scale-out events, time-to-first-pod-ready under load
- **Cost-normalized:** tokens / $ at on-demand and spot price (Cloud Billing API export)

All this lands in `benchmark/results/<timestamp>/` as JSON + Markdown + a side-by-side HTML report.

---

## What "max performance" looks like for Gemma 4 E4B

Quick orienting numbers so you know what you're aiming for. These are **rough order-of-magnitude expectations**, not guarantees:

| GPU | BF16 weights | Free for KV | Expected single-stream tok/s | Expected concurrent tok/s |
|---|---|---|---|---|
| L4 24 GB        | ~8 GB | ~12 GB | 60–100   | 800–1500 |
| RTX PRO 6000 96 GB | ~8 GB | ~80 GB | 200–350  | 4000–7000 |

llm-d's value over plain vLLM shows up most at **higher concurrency** and **with repeated prefixes** (KV-cache-aware routing). On a single replica with random unique prompts, you should see plain vLLM and llm-d within a few percent of each other — that's expected and isn't a bug.

---

## Cost guardrails

The default `provision.sh` creates each GPU nodepool with **0 nodes**, with cluster autoscaler enabled. Pods land → nodes spin up. Pods leave → after `--scale-down-unneeded-time` (10 min default) → nodes terminate. You won't pay for GPUs you aren't actively benchmarking, but a long benchmark sweep can still run into real money — keep an eye on the dashboard.

`make estimate-cost` prints a back-of-envelope cost for the full sweep based on current `gcloud compute machine-types` pricing.

---

## Support matrix this POC was validated against

| Component | Version |
|---|---|
| GKE control plane | 1.31+ (Inference Gateway requires 1.28.15-gke.2475000 or later) |
| llm-d | v0.7 (May 2026, "Optimized Baseline") |
| vLLM | 0.11+ (Gemma 4 support landed in the launch build) |
| Gateway API | v1.4.0 |
| Gateway API Inference Extension | v1.4.0 |
| Helm | 3.10+ |

Pin to these in CI; use `latest` at your own risk.
