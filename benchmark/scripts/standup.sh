#!/usr/bin/env bash
# =============================================================================
# standup.sh <stack> <size>
#
# stack: plain-vllm | llm-d
# size:  1gpu | 2gpu | 4gpu | 8gpu
# =============================================================================
set -euo pipefail

STACK="$1"
SIZE="$2"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

# Translate size to overlay/values-suffix.
case "${SIZE}" in
  1gpu) GPU_COUNT="1" ; OVERLAY="single-gpu" ; VALUES_SUFFIX=""      ;;
  2gpu) GPU_COUNT="2" ; OVERLAY="two-gpu"    ; VALUES_SUFFIX="-2gpu" ;;
  4gpu) GPU_COUNT="4" ; OVERLAY="four-gpu"   ; VALUES_SUFFIX="-4gpu" ;;
  8gpu) GPU_COUNT="8" ; OVERLAY="eight-gpu"  ; VALUES_SUFFIX="-8gpu" ;;
  *) echo "unknown size: ${SIZE} (expected: 1gpu, 2gpu, 4gpu, or 8gpu)" >&2 ; exit 1 ;;
esac

case "${STACK}" in
  plain-vllm)
    kubectl apply -k "${REPO_ROOT}/deploy/plain-vllm/overlays/${OVERLAY}"
    kubectl -n vllm-plain rollout status deploy/vllm-gemma --timeout=20m
    kubectl apply -f "${REPO_ROOT}/deploy/autoscaling/hpa-plain-vllm.yaml"
    ;;
  llm-d)
    # If the infra chart isn't installed yet, install it.
    if ! helm -n llm-d status llm-d-infra >/dev/null 2>&1; then
      helm install llm-d-infra llm-d-infra/llm-d-infra \
        -n llm-d -f "${REPO_ROOT}/deploy/llm-d/values-infra.yaml"
    fi

    VALUES_FILES=("-f" "${REPO_ROOT}/deploy/llm-d/values-modelservice-gemma4.yaml")
    if [[ -n "${VALUES_SUFFIX}" ]]; then
      VALUES_FILES+=("-f" "${REPO_ROOT}/deploy/llm-d/values-modelservice-gemma4${VALUES_SUFFIX}.yaml")
    fi

    if helm -n llm-d status gemma >/dev/null 2>&1; then
      helm upgrade gemma llm-d-modelservice/llm-d-modelservice -n llm-d "${VALUES_FILES[@]}"
    else
      helm install gemma llm-d-modelservice/llm-d-modelservice -n llm-d "${VALUES_FILES[@]}"
    fi

    kubectl -n llm-d rollout status deploy/gemma-decode --timeout=20m
    kubectl apply -f "${REPO_ROOT}/deploy/autoscaling/hpa-llm-d.yaml"
    ;;
  *) echo "unknown stack: ${STACK}" >&2 ; exit 1 ;;
esac

echo ">>> Stood up ${STACK} on ${SIZE}"
