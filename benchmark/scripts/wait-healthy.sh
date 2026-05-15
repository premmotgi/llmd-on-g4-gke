#!/usr/bin/env bash
# =============================================================================
# wait-healthy.sh <endpoint>
# Polls the endpoint until it answers a small chat completion successfully.
# =============================================================================
set -euo pipefail

ENDPOINT="$1"
TIMEOUT="${TIMEOUT:-1200}"
START="$(date +%s)"

echo ">>> Waiting for ${ENDPOINT} to serve a request (timeout ${TIMEOUT}s)…"
while true; do
  ELAPSED=$(( $(date +%s) - START ))
  if (( ELAPSED > TIMEOUT )); then
    echo "    ! timed out after ${TIMEOUT}s" >&2
    exit 1
  fi

  if curl -sf --max-time 5 "${ENDPOINT}/v1/models" -o /tmp/models.json; then
    if grep -q '"id"' /tmp/models.json; then
      # Try an actual completion — /v1/models can return success before the
      # KV cache is warm.
      RESP="$(curl -sf --max-time 30 -X POST "${ENDPOINT}/v1/chat/completions" \
              -H 'Content-Type: application/json' \
              -d '{"model":"gemma","messages":[{"role":"user","content":"hi"}],"max_tokens":4}' \
              || true)"
      if [[ "${RESP}" == *'"content"'* ]]; then
        echo "    ✓ healthy after ${ELAPSED}s"
        exit 0
      fi
    fi
  fi
  sleep 10
done
