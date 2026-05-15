#!/usr/bin/env bash
# =============================================================================
# benchmark/scripts/run-sweep.sh
#
# Walks the full cartesian product of:
#   {plain-vllm, llm-d}  ×  {1-GPU, 2-GPU, 4-GPU, 8-GPU node}  ×  scenarios
#
# Uses the official `llm-d-benchmark` harness (https://github.com/llm-d/llm-d-benchmark)
# for both stacks so the metrics are directly comparable.
#
# For plain vLLM we still use llm-d-benchmark — it can drive any OpenAI-compatible
# endpoint via the `external` standup mode. This guarantees the load generator,
# warmup, and metric extraction are identical between the two.
#
# Output: benchmark/results/<timestamp>/
# =============================================================================
set -euo pipefail

# Load shared env.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"
source "${REPO_ROOT}/.env"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${REPO_ROOT}/benchmark/results/${TS}"
mkdir -p "${RESULTS_DIR}"

echo ">>> Benchmark sweep starting — results: ${RESULTS_DIR}"

# --- 1) Make sure llm-d-benchmark is installed ------------------------------
if ! command -v llmdbenchmark &>/dev/null; then
  echo ">>> Installing llm-d-benchmark…"
  python3 -m venv "${REPO_ROOT}/.venv"
  source "${REPO_ROOT}/.venv/bin/activate"
  pip install --upgrade pip
  pip install "git+https://github.com/llm-d/llm-d-benchmark@v0.7.0#egg=llmdbenchmark"
fi

# --- 2) Sweep parameters ----------------------------------------------------
if [[ "${GPU_FAMILY}" == "g4" ]]; then
  GPU_SIZES=("1gpu" "2gpu" "4gpu" "8gpu")
else
  GPU_SIZES=("1gpu-small" "1gpu-mid" "2gpu" "4gpu")
fi

STACKS=("plain-vllm" "llm-d")
SCENARIOS=("low-concurrency" "mid-concurrency" "max-throughput")

# --- 3) Per-cell run --------------------------------------------------------
for STACK in "${STACKS[@]}"; do
  for SIZE in "${GPU_SIZES[@]}"; do
    for SCEN in "${SCENARIOS[@]}"; do

      CELL="${STACK}__${SIZE}__${SCEN}"
      CELL_DIR="${RESULTS_DIR}/${CELL}"
      mkdir -p "${CELL_DIR}"

      echo ""
      echo "============================================================"
      echo "  CELL: ${CELL}"
      echo "============================================================"

      # Bring the right deployment up.
      bash "${SCRIPT_DIR}/standup.sh" "${STACK}" "${SIZE}" | tee "${CELL_DIR}/standup.log"

      # Wait for the endpoint to be healthy.
      ENDPOINT="$(bash "${SCRIPT_DIR}/endpoint.sh" "${STACK}")"
      echo "ENDPOINT=${ENDPOINT}" > "${CELL_DIR}/endpoint.txt"

      bash "${SCRIPT_DIR}/wait-healthy.sh" "${ENDPOINT}"

      # Run the scenario.
      llmdbenchmark run \
        --spec "${REPO_ROOT}/benchmark/scenarios/${SCEN}.yaml.j2" \
        --endpoint "${ENDPOINT}" \
        --model "${MODEL_ID}" \
        --workspace "${CELL_DIR}" \
        --analyze \
        2>&1 | tee "${CELL_DIR}/bench.log"

      # Bring it down before the next cell — frees the nodepool.
      bash "${SCRIPT_DIR}/teardown-cell.sh" "${STACK}"
    done
  done
done

# --- 4) Combine into a comparison report ------------------------------------
echo ""
echo ">>> Building comparison report…"
python3 "${SCRIPT_DIR}/build-report.py" "${RESULTS_DIR}"

echo ""
echo ">>> Done. Open: ${RESULTS_DIR}/comparison-report.html"
