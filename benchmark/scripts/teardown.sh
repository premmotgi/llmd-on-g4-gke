#!/usr/bin/env bash
# =============================================================================
# teardown.sh — full teardown. Run when the POC is done.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"
source "${REPO_ROOT}/.env"

echo ">>> Uninstalling Helm releases…"
helm -n llm-d uninstall gemma          || true
helm -n llm-d uninstall llm-d-infra    || true

echo ">>> Deleting plain-vllm…"
kubectl delete ns vllm-plain --ignore-not-found

echo ">>> Deleting llm-d namespace…"
kubectl delete ns llm-d --ignore-not-found

echo ">>> Destroying the cluster + nodepools…"
YES=1 bash "${REPO_ROOT}/infra/scripts/destroy.sh"

echo ">>> Done."
