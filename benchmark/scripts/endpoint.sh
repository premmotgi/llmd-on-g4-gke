#!/usr/bin/env bash
# =============================================================================
# endpoint.sh <stack>
#
# Echoes a usable HTTP base URL for the given stack. For plain-vllm we open a
# port-forward (the benchmark runs inside the same network anyway when launched
# as an in-cluster Job, but we support local runs too).
# =============================================================================
set -euo pipefail

STACK="$1"

case "${STACK}" in
  plain-vllm)
    # The Service is ClusterIP — easiest is in-cluster DNS.
    echo "http://vllm-gemma.vllm-plain.svc.cluster.local"
    ;;
  llm-d)
    # The infra chart exposes a Gateway; grab its assigned address.
    ADDR="$(kubectl -n llm-d get gateway llm-d-infra-gateway \
              -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
    if [[ -z "${ADDR}" ]]; then
      echo "Gateway not yet assigned an address" >&2
      exit 1
    fi
    echo "http://${ADDR}"
    ;;
  *) echo "unknown stack: ${STACK}" >&2 ; exit 1 ;;
esac
