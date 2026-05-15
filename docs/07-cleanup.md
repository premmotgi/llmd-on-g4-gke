# 07 — Cleanup

After the POC, tear everything down. Idle clusters with GPU nodepools at min=0 are cheap (~$72/mo for the control plane) but not free. If your demo is over, kill it.

## One command

```bash
bash benchmark/scripts/teardown.sh
```

This:

1. `helm uninstall gemma` (in `llm-d` namespace)
2. `helm uninstall llm-d-infra`
3. `kubectl delete ns vllm-plain llm-d`
4. `bash infra/scripts/destroy.sh` — deletes the cluster, all nodepools, the service account, and the Secret Manager secret

Total time: ~5 min (most of it waiting for GKE to delete the cluster).

## Verifying it's actually gone

GKE clusters sometimes leave orphaned resources if delete is interrupted:

```bash
gcloud container clusters list --project="${PROJECT_ID}"
# Should be empty (or not show gemma-poc).

gcloud compute disks list --project="${PROJECT_ID}" \
  --filter="name~'gke-gemma-poc'"
# Should be empty. If not, delete manually — orphaned disks bill at ~$0.04/GB/month.

gcloud compute forwarding-rules list --project="${PROJECT_ID}"
# Look for any Gateway-related L7 LBs that didn't clean up.

gcloud secrets list --project="${PROJECT_ID}" --filter="name~'hf-token'"
# destroy.sh removes this, but verify.
```

## Saving the results

The teardown script does **not** delete `benchmark/results/`. The numbered subdirectories are timestamped, and the comparison reports inside them are self-contained HTML/CSV. Commit them or move them to Drive/Cloud Storage before recycling your local checkout.

```bash
gsutil -m cp -r benchmark/results gs://your-bucket/gemma-poc-results/
```

## Leaving the cluster up for a follow-up demo

If you want to keep the cluster but not pay for GPUs:

- Full `destroy.sh` is overkill. Instead:
  ```bash
  helm -n llm-d uninstall gemma
  kubectl -n vllm-plain delete deploy vllm-gemma
  ```
- The cluster autoscaler will scale all GPU nodepools back to 0 within `--scale-down-unneeded-time` (default 10 min). After that you're paying control-plane only.
- Bring workloads back with `bash benchmark/scripts/standup.sh ...`. No need to re-run `provision.sh`.

## Common cleanup failures

- **`Error 400: The fleet membership ... is referenced by …`**: GKE leaves a fleet membership record sometimes. Delete it manually:
  ```bash
  gcloud container fleet memberships delete gemma-poc --project="${PROJECT_ID}"
  ```
- **`Cannot delete: forwarding rule ... in use`**: a Gateway-provisioned L7 LB hasn't released the rule. Wait 2 min and re-run destroy.
- **`destroy.sh` complains the cluster is missing but resources remain**: someone deleted the cluster in the console out of band. Run the per-resource cleanup commands at the top of `destroy.sh` directly (SA delete, secret delete), or just ignore — the orphan check at the end will surface anything billable.

That's it. POC complete.
