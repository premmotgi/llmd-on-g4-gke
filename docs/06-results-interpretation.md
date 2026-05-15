# 06 — Results Interpretation

How to read the comparison report, what to expect, and how to spot when something's wrong.

## The comparison report

`comparison-report.html` shows one table per scenario. Each table has two rows per machine size — one plain-vllm, one llm-d — colored beige and blue respectively. Green numbers mark the winner in each (row pair, column) cell.

Read it in this order:

1. **Find the saturation point.** In `max-throughput`, look for the row pair where TTFT p99 first exceeds your SLA. That's the operating ceiling for that machine type. Anything beyond is "the system is failing gracefully."
2. **Compare stacks at the saturation point**, not below it. Below saturation both stacks should look nearly identical — that's expected. The whole point of llm-d's intelligent routing is to delay or push out the saturation point.
3. **Look at `kv_cache_hit_rate` in mid-concurrency**. This is where llm-d's prefix-cache-aware routing differentiates itself. If you see plain-vllm at ~5% and llm-d at ~25%+ on the 4-GPU or 8-GPU multi-replica rows, that's the headline number.

## Expected patterns

### When llm-d ≈ plain vLLM (and that's correct)

- **1 GPU, 1 replica, any concurrency**: llm-d's whole story is multi-replica routing. With one pod there's nothing to route to. Expect numbers within ±5%.
- **Random prompts, no prefix overlap**: even multi-replica, prefix-cache-aware routing has nothing to optimize. Plain round-robin from kube-proxy and llm-d's EPP should produce similar load distributions.
- **Single-stream, concurrency=1**: latency is dominated by the underlying vLLM, not the routing layer.

### When llm-d should clearly win

- **Multi-replica + prefix sharing**: the `mid-concurrency` scenario with `shared_prefix_ratio: 0.30` is designed to surface this. Expect 1.3–2× output throughput improvement and significantly lower TTFT p99.
- **8 GPUs as 8 replicas + prefix cache offload enabled**: this is the headline llm-d configuration. Expect the biggest gap.
- **Bursty traffic past saturation**: llm-d's load-aware routing keeps the queue distribution smoother across replicas, so p99 latencies hold up while plain vLLM's p99 explodes on whichever replica happened to get the slow request.

### When plain vLLM should be ahead (small but real)

- **Very low concurrency on a single replica**: the EPP adds ~1–3 ms of routing overhead per request. At concurrency=1 with short prompts this is measurable. Don't be alarmed.

## Red flags

### "Both stacks are pinned at low throughput"

- Check `gpu_memory_utilization`. Default is 0.90; if vLLM can't allocate that much (because other processes are using the GPU), it'll silently fall back to a tiny KV cache and throughput craters. Tail logs for `available GPU memory`.
- Check `max-model-len`. Default 32768 reserves KV cache for that length. If you bumped it to 131072, the KV cache shrinks proportionally and concurrent batch size drops.

### "TTFT goes up at low load but is fine at high load"

This is usually nodepool cold-start, not the model. Look at `replica_count` and `node_count` over time in the dashboard — if a new node came up during the run, the requests that hit it cold paid for the model download. Either pre-warm before benchmarking or filter the first N seconds.

### "llm-d is *worse* than plain vLLM"

Three common causes:

1. **Routing mode misconfigured**. Verify `inferenceScheduler.routing.mode` in `values-infra.yaml` matches your workload — `prefix-aware` only helps when prompts share prefixes.
2. **Single-replica deployment**. Bump `decode.replicas` to at least 2; the routing layer can't help if there's nothing to route across.
3. **EPP running on a CPU-starved system node**. Check `kubectl top pod -n llm-d`; if the EPP is throttled, latency comes from there. Bump CPU requests for the EPP.

### "Throughput is fine but the cost number looks terrible"

The CSV summary normalizes by on-demand price. If you ran on Spot, the cost-per-token will look great there. If you ran on Flex-Start, the cost matches on-demand but with provisioning lag — factor that into the comparison.

## What to put in front of the customer

For an executive summary, three numbers usually land best:

1. **Max sustained tok/s per dollar** at the SLA cutoff — one number per (stack, machine) cell. This is what they actually pay for.
2. **TTFT p99 at target concurrency** — the user-facing latency promise.
3. **Cold-start time** (from autoscale-burst) — the worst-case latency when the burst hits.

Resist the temptation to lead with the highest absolute throughput number; that's usually the 8-GPU max-throughput cell, which is rarely the right buy.

## The .csv is the source of truth

`comparison-summary.csv` is what you use for further analysis. Load it in Sheets, Pandas, whatever. The HTML is for skimming; the CSV is for plotting and presenting.

Example: a one-liner that ranks the top 5 (machine, stack) cells by output_throughput_tps with TTFT p99 under 2000ms:

```bash
awk -F, 'NR==1 || ($4!="" && $4+0 < 2000)' comparison-summary.csv \
  | sort -t, -k6 -rn | head -6 | column -t -s,
```

Next: [07-cleanup.md](./07-cleanup.md)
