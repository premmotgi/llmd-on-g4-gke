#!/usr/bin/env bash
# =============================================================================
# teardown-cell.sh <stack>
# Removes a single cell's deployment so the next cell starts clean.
# Cluster-level resources (CRDs, gateway, namespace) stay.
# =============================================================================
set -euo pipefail

STACK="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

case "${STACK}" in
  plain-vllm)
    kubectl -n vllm-plain delete deploy vllm-gemma --ignore-not-found
    kubectl -n vllm-plain delete hpa vllm-gemma --ignore-not-found
    ;;
  llm-d)
    helm -n llm-d uninstall gemma || true
    kubectl -n llm-d delete hpa gemma-decode --ignore-not-found
    ;;
  *) echo "unknown stack: ${STACK}" >&2 ; exit 1 ;;
esac

echo ">>> Cell ${STACK} torn down."
