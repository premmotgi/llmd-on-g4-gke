# =============================================================================
# Gemma-on-GKE POC — convenience targets. All shell out to the scripts in
# benchmark/scripts/ and deploy/. Run `make help` to list them.
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Pull env from .env if it exists, otherwise complain.
ifneq (,$(wildcard .env))
include .env
export
endif

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Infrastructure ---------------------------------------------------------

.PHONY: provision
provision: ## Provision the GKE cluster + GPU nodepools (~10 min)
	bash infra/scripts/provision.sh

.PHONY: destroy
destroy: ## Destroy the GKE cluster + everything provision.sh created
	bash infra/scripts/destroy.sh

.PHONY: kubeconfig
kubeconfig: ## Update kubeconfig for the POC cluster
	gcloud container clusters get-credentials "$(CLUSTER_NAME)" \
	  --region "$(REGION)" --project "$(PROJECT_ID)"

# --- Prereqs ----------------------------------------------------------------

.PHONY: prereqs
prereqs: ## Install Gateway API + Inference Extension CRDs + CMSA + Helm repos
	bash deploy/llm-d/00-prereqs.sh
	bash deploy/autoscaling/install-cmsa.sh

.PHONY: hf-secret
hf-secret: ## Push the HF token into Secret Manager (uses HF_TOKEN from .env)
	@[ -n "$(HF_TOKEN)" ] || { echo "HF_TOKEN not set"; exit 1; }
	gcloud secrets versions add hf-token --project="$(PROJECT_ID)" \
	  --data-file=<(printf '%s' '$(HF_TOKEN)')

# --- Deploy -----------------------------------------------------------------

.PHONY: deploy-plain
deploy-plain: ## Deploy plain vLLM (single-gpu overlay)
	@[ -n "$(PROJECT_ID)" ] || { echo "PROJECT_ID not set"; exit 1; }
	sed -i.bak "s/PROJECT_ID/$(PROJECT_ID)/g" deploy/plain-vllm/base/serviceaccount.yaml
	kubectl apply -k deploy/plain-vllm/overlays/single-gpu
	kubectl apply -f deploy/autoscaling/hpa-plain-vllm.yaml

.PHONY: deploy-llmd
deploy-llmd: ## Deploy llm-d infra + Gemma modelservice (1-GPU)
	helm upgrade --install llm-d-infra llm-d-infra/llm-d-infra \
	  -n llm-d -f deploy/llm-d/values-infra.yaml
	helm upgrade --install gemma llm-d-modelservice/llm-d-modelservice \
	  -n llm-d -f deploy/llm-d/values-modelservice-gemma4.yaml
	kubectl apply -f deploy/autoscaling/hpa-llm-d.yaml

# --- Benchmarks -------------------------------------------------------------

.PHONY: bench-single
bench-single: ## Run a single cell — STACK=plain-vllm SIZE=1gpu SCENARIO=low-concurrency
	@[ -n "$(STACK)" ] && [ -n "$(SIZE)" ] && [ -n "$(SCENARIO)" ] || \
	  { echo "usage: make bench-single STACK=plain-vllm SIZE=1gpu SCENARIO=low-concurrency"; exit 1; }
	bash benchmark/scripts/standup.sh $(STACK) $(SIZE)
	@ENDPOINT=$$(bash benchmark/scripts/endpoint.sh $(STACK)); \
	 bash benchmark/scripts/wait-healthy.sh "$$ENDPOINT"; \
	 source .venv/bin/activate && \
	 llmdbenchmark run \
	   --spec benchmark/scenarios/$(SCENARIO).yaml.j2 \
	   --endpoint "$$ENDPOINT" \
	   --model "$(MODEL_ID)" \
	   --workspace /tmp/$(STACK)-$(SIZE)-$(SCENARIO) \
	   --analyze

.PHONY: bench-sweep
bench-sweep: ## Run the full sweep — ~3-5 hrs, expensive
	bash benchmark/scripts/run-sweep.sh

.PHONY: bench-autoscale
bench-autoscale: ## Run only the autoscale-burst scenario on llm-d 1gpu
	$(MAKE) bench-single STACK=llm-d SIZE=1gpu SCENARIO=autoscale-burst

# --- Estimation -------------------------------------------------------------

.PHONY: estimate-cost
estimate-cost: ## Print a rough cost estimate for the full sweep
	@python3 -c "import json,sys; \
	prices_g4={'g4-standard-48':5.5,'g4-standard-96':11,'g4-standard-192':22,'g4-standard-384':44}; \
	prices_g2={'g2-standard-4':0.7,'g2-standard-12':1.1,'g2-standard-24':2.1,'g2-standard-48':5.5}; \
	prices=prices_g4 if '$(GPU_FAMILY)'=='g4' else prices_g2; \
	mult=0.3 if '$(PROVISIONING_MODE)'=='spot' else 1.0; \
	per_size_hours=1.0; \
	total=sum(p*per_size_hours*mult for p in prices.values()); \
	print(f'Rough sweep cost ($(GPU_FAMILY), $(PROVISIONING_MODE)): \$$ {total:.2f} USD'); \
	print('Assumes 1 hr/machine size at peak load. Real spend depends on');\
	print('cold-start time, queue waits, and how much you iterate.')"

# --- Teardown ---------------------------------------------------------------

.PHONY: teardown-cell
teardown-cell: ## Tear down a single cell — STACK=plain-vllm
	@[ -n "$(STACK)" ] || { echo "usage: make teardown-cell STACK=plain-vllm"; exit 1; }
	bash benchmark/scripts/teardown-cell.sh $(STACK)

.PHONY: teardown
teardown: ## Tear down everything, including the cluster
	bash benchmark/scripts/teardown.sh
