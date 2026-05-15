# 05 — Run the Benchmark

End-to-end sweep that produces a side-by-side comparison report.

## What it runs

The driver script (`benchmark/scripts/run-sweep.sh`) walks this cartesian product:

```
  {plain-vllm, llm-d}   ×   {1, 2, 4, 8 GPU nodes}   ×   {3 scenarios}
```

Each cell follows the same lifecycle:

1. **Standup** — apply Kustomize overlay or `helm upgrade` to land on the right nodepool
2. **Wait healthy** — poll until `/v1/chat/completions` returns
3. **Run** — `llmdbenchmark run --spec <scenario> --endpoint <url>`
4. **Teardown cell** — uninstall so the next cell starts clean

We use the same harness (`llm-d-benchmark`) against both stacks so plain vLLM and llm-d numbers are directly comparable. The harness wraps `vllm bench serve` and adds standardized warmup, percentile reporting, and the cross-treatment analysis pipeline.

## Scenarios

| File | What it measures | Run time per cell |
|---|---|---|
| `low-concurrency.yaml.j2` | Interactive-chat latency at 1/4/16 concurrent users | ~3 min |
| `mid-concurrency.yaml.j2` | 32/64/128 concurrent users with 30% prefix-sharing — where llm-d's routing should pull ahead | ~5 min |
| `max-throughput.yaml.j2` | Saturate the system, find the tok/s ceiling per chip | ~8 min |
| `autoscale-burst.yaml.j2` | HPA + cluster autoscaler validation (run separately) | ~5 min |

Defaults: ShareGPT prompts, 256/512/1024 input tokens × 256/512 output tokens, seed 42. Tune in the scenario files.

## Run the sweep

```bash
source .env

# Make all the scripts executable once
chmod +x benchmark/scripts/*.sh deploy/llm-d/00-prereqs.sh deploy/autoscaling/install-cmsa.sh

# Run it
bash benchmark/scripts/run-sweep.sh
```

Full sweep on G4 (4 sizes × 2 stacks × 3 scenarios = 24 cells): **~3–5 hours** including all the nodepool scale-ups and the inevitable Gemma 4 download on first hit per node. Cells with the same machine size reuse the warm node, so the second stack on a given size starts in ~2 min instead of ~10.

Output:

```
benchmark/results/20260515T180000Z/
├── plain-vllm__1gpu__low-concurrency/
│   ├── benchmark_report.json
│   ├── bench.log
│   ├── analysis/                 # per-request distribution plots
│   └── standup.log
├── plain-vllm__1gpu__mid-concurrency/
├── …
├── llm-d__8gpu__max-throughput/
├── comparison-report.html        # ← open this
├── comparison-report.md
└── comparison-summary.csv
```

## Running a single cell

For iterating on one config without burning the full sweep:

```bash
# Stand up
bash benchmark/scripts/standup.sh llm-d 4gpu

# Wait until healthy (the script logs when it succeeds)
ENDPOINT=$(bash benchmark/scripts/endpoint.sh llm-d)
bash benchmark/scripts/wait-healthy.sh "${ENDPOINT}"

# Run one scenario
source .venv/bin/activate
llmdbenchmark run \
  --spec benchmark/scenarios/mid-concurrency.yaml.j2 \
  --endpoint "${ENDPOINT}" \
  --model "${MODEL_ID}" \
  --workspace /tmp/single-cell \
  --analyze

# Tear down
bash benchmark/scripts/teardown-cell.sh llm-d
```

## Running the autoscaling validation separately

The HPA scenario is best run in isolation so the noise from other scenarios doesn't pollute the time-to-replica numbers:

```bash
bash benchmark/scripts/standup.sh llm-d 1gpu
ENDPOINT=$(bash benchmark/scripts/endpoint.sh llm-d)

# Watch the HPA and replica count in another terminal
kubectl -n llm-d get hpa,deploy -w &

llmdbenchmark run \
  --spec benchmark/scenarios/autoscale-burst.yaml.j2 \
  --endpoint "${ENDPOINT}" \
  --model "${MODEL_ID}" \
  --workspace /tmp/autoscale-test \
  --analyze
```

You should see the HPA scale from 1 → ~4 replicas during the burst phase, then back to 1 after the cooldown window.

## What "good" looks like

Rough expectations for Gemma 4 E4B-it with BF16 weights:

| Stack | GPU | Concurrency | Output tok/s (aggregate) | TTFT p50 | TPOT p50 |
|---|---|---|---|---|---|
| plain-vllm | 1× L4 | 32  | 700–900   | 200–400 ms | 25–40 ms |
| llm-d      | 1× L4 | 32  | 700–950   | 200–400 ms | 25–40 ms |
| plain-vllm | 4× L4 (1 replica TP=4) | 128 | 2200–2800 | 400–600 ms | 30–50 ms |
| plain-vllm | 4× L4 (4 replicas DP=4) | 128 | 3000–3800 | 250–500 ms | 25–45 ms |
| llm-d      | 4× L4 (4 replicas) | 128 | 3500–4500 | 200–450 ms | 25–45 ms |
| plain-vllm | 1× RTX PRO 6000 | 128 | 3500–5000 | 200–400 ms | 20–35 ms |
| llm-d      | 1× RTX PRO 6000 | 128 | 3500–5000 | 200–400 ms | 20–35 ms |
| llm-d      | 8× RTX PRO 6000 (8 replicas + prefix-cache offload) | 512 | 30k–45k | 300–700 ms | 25–40 ms |

These are order-of-magnitude orienting numbers, not promises. The real numbers come out of the report. If your numbers are wildly off these, see [06-results-interpretation.md](./06-results-interpretation.md).

## Cost while running

Approximate on-demand pricing in `us-central1` for the sweep:

| Machine | $/hr | Time at peak load during sweep | Cost contribution |
|---|---|---|---|
| g4-standard-48 (1× RTX PRO 6000) | ~$5–6 | ~30 min | ~$3 |
| g4-standard-96 | ~$10–12 | ~30 min | ~$5 |
| g4-standard-192 | ~$20–24 | ~30 min | ~$11 |
| g4-standard-384 | ~$40–48 | ~30 min | ~$22 |
| g2-standard-4 (1× L4) | ~$0.70 | ~30 min | ~$0.40 |
| g2-standard-48 (4× L4) | ~$5–6 | ~30 min | ~$3 |

Spot pricing cuts these by 60–80%. Use it for the sweep unless you specifically want preemption-free numbers.

Always sanity-check current pricing with:

```bash
gcloud compute machine-types describe g4-standard-48 --zone=us-central1-a \
  --format="value(name,description)"
# Pricing is at https://cloud.google.com/compute/all-pricing
```

Next: [06-results-interpretation.md](./06-results-interpretation.md)
