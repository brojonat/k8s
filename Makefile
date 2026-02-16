CLUSTER ?= firekeeper
KUBECONFIG_PATH := $(CLUSTER)/kubeconfig
KC := KUBECONFIG=$(KUBECONFIG_PATH)
TEMPORAL_NS ?= g2i

# --- Infrastructure (Helm) ---

.PHONY: apply-cert-manager
apply-cert-manager:
	$(KC) helm repo add jetstack https://charts.jetstack.io --force-update
	$(KC) helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager --create-namespace \
		--values $(CLUSTER)/infra/cert-manager/helm-values.yaml \
		--wait
	$(KC) kubectl apply -f $(CLUSTER)/infra/cert-manager/cluster-issuer.yaml

.PHONY: apply-nats
apply-nats:
	$(KC) helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update
	$(KC) helm upgrade --install nats nats/nats \
		--namespace nats --create-namespace \
		--values $(CLUSTER)/infra/nats/helm-values.yaml \
		--wait

.PHONY: apply-temporal
apply-temporal:
	@. ./.env 2>/dev/null || true; \
	if [ -z "$$TEMPORAL_DB_PASSWORD" ]; then \
		echo "Error: TEMPORAL_DB_PASSWORD must be set in .env"; exit 1; \
	fi; \
	$(KC) kubectl create namespace temporal 2>/dev/null || true; \
	$(KC) kubectl create secret generic temporal-default-store -n temporal \
		--from-literal=password=$$TEMPORAL_DB_PASSWORD \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -; \
	$(KC) kubectl create secret generic temporal-visibility-store -n temporal \
		--from-literal=password=$$TEMPORAL_DB_PASSWORD \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -
	$(KC) helm repo add temporal https://temporalio.github.io/helm-charts --force-update
	$(KC) helm upgrade --install temporal temporal/temporal \
		--namespace temporal --create-namespace \
		--values $(CLUSTER)/infra/temporal/helm-values.yaml \
		--timeout 15m \
		--wait

.PHONY: apply-tailscale
apply-tailscale:
	@. ./.env 2>/dev/null || true; \
	if [ -z "$$TAILSCALE_CLIENT_ID" ] || [ -z "$$TAILSCALE_CLIENT_SECRET" ]; then \
		echo "Error: TAILSCALE_CLIENT_ID and TAILSCALE_CLIENT_SECRET must be set in .env"; exit 1; \
	fi; \
	$(KC) kubectl create namespace tailscale 2>/dev/null || true; \
	$(KC) kubectl create secret generic operator-oauth -n tailscale \
		--from-literal=client_id=$$TAILSCALE_CLIENT_ID \
		--from-literal=client_secret=$$TAILSCALE_CLIENT_SECRET \
		--dry-run=client -o yaml | $(KC) kubectl apply -f -
	$(KC) helm repo add tailscale https://pkgs.tailscale.com/helmcharts --force-update
	$(KC) helm upgrade --install tailscale-operator tailscale/tailscale-operator \
		--namespace tailscale --create-namespace \
		--values $(CLUSTER)/infra/tailscale/helm-values.yaml \
		--wait

.PHONY: apply-infra
apply-infra: apply-cert-manager apply-nats apply-temporal apply-tailscale
	@echo "All infrastructure deployed to $(CLUSTER)"

# --- Monitoring ---

.PHONY: apply-monitoring
apply-monitoring:
	@$(KC) kubectl apply -k $(CLUSTER)/monitoring/
	@for f in $(CLUSTER)/monitoring/patches/*.yaml; do \
		name=$$(grep 'name:' $$f | head -1 | awk '{print $$2}'); \
		$(KC) kubectl patch deployment $$name -n default --patch-file $$f || echo "Warning: failed to patch $$name"; \
	done
	@for f in $(CLUSTER)/monitoring/alerts/*.yaml; do \
		key=$$(basename $$f); \
		$(KC) kubectl get configmap temporal-prometheus-server -n temporal -o json | \
			jq --arg key "$$key" --rawfile content "$$f" '.data[$$key] = $$content' | \
			$(KC) kubectl apply -f - 2>&1 | grep -v "Warning: resource.*missing.*annotation" || true; \
	done
	@echo "Monitoring applied. Reloading Prometheus..."
	@$(KC) kubectl exec -n temporal deployment/temporal-prometheus-server -c prometheus-server -- killall -HUP prometheus 2>/dev/null || true

# --- Temporal Admin ---

.PHONY: temporal-namespaces
temporal-namespaces:
	$(KC) kubectl exec -n temporal deployment/temporal-admintools -- tctl namespace list

.PHONY: temporal-schedules
temporal-schedules:
	$(KC) kubectl exec -n temporal deployment/temporal-admintools -- tctl --ns $(TEMPORAL_NS) schedule list

.PHONY: temporal-workflows
temporal-workflows:
	$(KC) kubectl exec -n temporal deployment/temporal-admintools -- tctl --ns $(TEMPORAL_NS) workflow list

.PHONY: temporal-create-ns
temporal-create-ns:
	$(KC) kubectl exec -n temporal deployment/temporal-admintools -- tctl --ns $(TEMPORAL_NS) namespace register
