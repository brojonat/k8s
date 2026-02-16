CLUSTER ?= do-sfo3-k8s-starter
KUBECONFIG_PATH := $(CLUSTER)/kubeconfig
KC := KUBECONFIG=$(KUBECONFIG_PATH)
APP ?=
SERVICE ?= forohtoo

# --- Cluster Status ---

.PHONY: status
status:
	$(KC) kubectl get nodes -o wide
	@echo "---"
	$(KC) kubectl get pods -A --field-selector=status.phase!=Succeeded
	@echo "---"
	$(KC) kubectl get svc -A
	@echo "---"
	$(KC) kubectl get ingress -A

# --- Infrastructure ---

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

# --- Diff / Verify ---

.PHONY: diff-clusters
diff-clusters:
	@echo "=== Infra diffs ==="
	diff -ru do-sfo3-k8s-starter/infra/ firekeeper/infra/ || true
	@echo ""
	@echo "=== Monitoring diffs ==="
	diff -ru do-sfo3-k8s-starter/monitoring/ firekeeper/monitoring/ || true

.PHONY: verify-migration
verify-migration:
	@echo "=== Checking all deployments in $(CLUSTER) ==="
	$(KC) kubectl get deployments -A -o wide
	@echo ""
	@echo "=== Pods not Running ==="
	$(KC) kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || echo "All pods healthy"
	@echo ""
	@echo "=== Ingresses ==="
	$(KC) kubectl get ingress -A
	@echo ""
	@echo "=== Certificates ==="
	$(KC) kubectl get certificates -A 2>/dev/null || echo "No certificates found"

# =============================================================================
# Monitoring
# =============================================================================

# --- Access UIs ---

.PHONY: grafana
grafana: ## Start Grafana port-forward (http://localhost:3000)
	@echo "Starting Grafana port-forward..."
	@pkill -f 'port-forward.*grafana' 2>/dev/null || true
	@$(KC) kubectl port-forward -n default svc/temporal-grafana 3000:80 > /dev/null 2>&1 &
	@sleep 2
	@echo "Grafana available at http://localhost:3000"
	@echo "   Username: admin"
	@echo "   Password: Run 'make print-grafana-password CLUSTER=$(CLUSTER)'"

.PHONY: prometheus
prometheus: ## Start Prometheus port-forward (http://localhost:9090)
	@echo "Starting Prometheus port-forward..."
	@pkill -f 'port-forward.*prometheus-server' 2>/dev/null || true
	@$(KC) kubectl port-forward -n default svc/temporal-prometheus-server 9090:80 > /dev/null 2>&1 &
	@sleep 2
	@echo "Prometheus available at http://localhost:9090"

.PHONY: alertmanager
alertmanager: ## Start AlertManager port-forward (http://localhost:9093)
	@echo "Starting AlertManager port-forward..."
	@pkill -f 'port-forward.*alertmanager' 2>/dev/null || true
	@$(KC) kubectl port-forward -n default svc/temporal-alertmanager 9093:9093 > /dev/null 2>&1 &
	@sleep 2
	@echo "AlertManager available at http://localhost:9093"

.PHONY: worker-metrics
worker-metrics: ## Port-forward worker metrics (SERVICE=forohtoo, default)
	@echo "Starting $(SERVICE) worker metrics port-forward..."
	@pkill -f 'port-forward.*worker-metrics.*9000' 2>/dev/null || true
	@svc=$$($(KC) kubectl get svc -n default -o jsonpath='{.items[?(@.spec.ports[0].port==9000)].metadata.name}' -l app=$(SERVICE)-worker 2>/dev/null || \
		$(KC) kubectl get svc -n default -o jsonpath='{.items[?(@.spec.ports[0].port==9000)].metadata.name}' -l app=$(SERVICE) 2>/dev/null); \
	if [ -z "$$svc" ]; then echo "No metrics service found for $(SERVICE). Run 'make apply-services CLUSTER=$(CLUSTER)' first."; exit 1; fi; \
	echo "Port-forwarding $$svc..."; \
	$(KC) kubectl port-forward -n default svc/$$svc 9000:9000 > /dev/null 2>&1 &
	@sleep 2
	@echo "Worker metrics available at http://localhost:9000/metrics"

.PHONY: all-uis
all-uis: grafana prometheus alertmanager ## Start all monitoring UIs
	@echo ""
	@echo "All monitoring UIs started:"
	@echo "   Grafana:      http://localhost:3000 (user: admin, run 'make print-grafana-password')"
	@echo "   Prometheus:   http://localhost:9090"
	@echo "   AlertManager: http://localhost:9093"
	@echo "   Worker:       make worker-metrics SERVICE=<name>"

.PHONY: tailscale-grafana
tailscale-grafana: ## Show Tailscale Grafana URL (no port-forward needed)
	@echo "Grafana via Tailscale:"
	@echo "   http://default-temporal-grafana (port 80)"
	@echo "   Username: admin"
	@echo "   Password: Run 'make print-grafana-password CLUSTER=$(CLUSTER)'"

.PHONY: stop-all
stop-all: ## Stop all port-forwards
	@echo "Stopping all port-forwards..."
	@pkill -f 'kubectl port-forward' 2>/dev/null || true
	@echo "All port-forwards stopped"

# --- Credentials ---

.PHONY: print-grafana-password
print-grafana-password: ## Print Grafana admin password
	@echo "Grafana Admin Password:"
	@$(KC) kubectl get secret -n default temporal-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d && echo || echo "Error: Could not retrieve password"

.PHONY: print-grafana-creds
print-grafana-creds: ## Print Grafana credentials (user + password)
	@echo "Grafana Credentials:"
	@echo "  Username: admin"
	@echo -n "  Password: "
	@$(KC) kubectl get secret -n default temporal-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d && echo || echo "Error"

# --- Monitoring Resources ---

.PHONY: apply-services
apply-services: ## Apply all worker metrics services via Kustomize
	@echo "Applying all worker metrics services..."
	@$(KC) kubectl apply -k $(CLUSTER)/monitoring/
	@echo "All metrics services applied"

.PHONY: apply-patches
apply-patches: ## Apply deployment patches for all workers + temporal-matching
	@echo "Applying deployment patches..."
	@for f in $(CLUSTER)/monitoring/patches/*.yaml; do \
		name=$$(grep 'name:' $$f | head -1 | awk '{print $$2}'); \
		echo "Patching deployment $$name..."; \
		$(KC) kubectl patch deployment $$name -n default --patch-file $$f || echo "  Warning: failed to patch $$name"; \
	done
	@echo "All deployment patches applied"

.PHONY: apply-alerts
apply-alerts: ## Apply all alert rules to Prometheus ConfigMap
	@echo "Applying alert rules..."
	@for f in $(CLUSTER)/monitoring/alerts/*.yaml; do \
		key=$$(basename $$f); \
		echo "Loading $$key..."; \
		$(KC) kubectl get configmap temporal-prometheus-server -n default -o json | \
			jq --arg key "$$key" --rawfile content "$$f" '.data[$$key] = $$content' | \
			$(KC) kubectl apply -f - 2>&1 | grep -v "Warning: resource.*missing.*annotation" || true; \
	done
	@echo "Alert rules applied"
	@echo "Run 'make reload-prometheus CLUSTER=$(CLUSTER)' to activate"

.PHONY: apply-monitoring
apply-monitoring: apply-services apply-patches apply-alerts ## Apply all monitoring resources
	@echo "All monitoring resources applied"

# --- Prometheus Management ---

.PHONY: reload-prometheus
reload-prometheus: ## Reload Prometheus configuration (after updating rules)
	@echo "Reloading Prometheus..."
	@$(KC) kubectl exec -n default deployment/temporal-prometheus-server -c prometheus-server -- killall -HUP prometheus 2>/dev/null || \
		echo "Failed to send reload signal. Prometheus may need restart."
	@sleep 3
	@echo "Prometheus reload signal sent"

.PHONY: restart-prometheus
restart-prometheus: ## Restart Prometheus pod (full restart)
	@echo "Restarting Prometheus..."
	@$(KC) kubectl delete pod -n default -l app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server
	@echo "Waiting for pod to restart..."
	@$(KC) kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server -n default --timeout=60s
	@echo "Prometheus restarted"

.PHONY: show-prometheus-config
show-prometheus-config: ## Show current Prometheus configuration
	@$(KC) kubectl exec -n default deployment/temporal-prometheus-server -c prometheus-server -- cat /etc/config/prometheus.yml

.PHONY: check-storage
check-storage: ## Check Prometheus storage usage
	@echo "Prometheus Storage Usage:"
	@$(KC) kubectl exec -n default deployment/temporal-prometheus-server -c prometheus-server -- df -h /data | tail -1

# --- Status Checks ---

.PHONY: monitoring-status
monitoring-status: ## Show overall monitoring status
	@echo "=== Monitoring Status ($(CLUSTER)) ==="
	@echo ""
	@echo "Prometheus:"
	@$(KC) kubectl get pod -l app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server -n default -o wide 2>/dev/null || echo "  Not found"
	@echo ""
	@echo "Grafana:"
	@$(KC) kubectl get pod -l app.kubernetes.io/name=grafana -n default -o wide 2>/dev/null || echo "  Not found"
	@echo ""
	@echo "AlertManager:"
	@$(KC) kubectl get pod -l app.kubernetes.io/name=alertmanager -n default -o wide 2>/dev/null || echo "  Not found"
	@echo ""
	@echo "Worker Metrics Services:"
	@$(KC) kubectl get svc -n default -o custom-columns=NAME:.metadata.name,CLUSTER-IP:.spec.clusterIP,PORT:.spec.ports[0].port 2>/dev/null | grep worker-metrics || echo "  None found (run 'make apply-services CLUSTER=$(CLUSTER)')"
	@echo ""
	@echo "Worker Pods:"
	@$(KC) kubectl get pod -n default -o wide -l 'app in (forohtoo-worker, affiliate-bounty-board, deadman, diddlylift, eth-notification-workers, gip-worker, kaggo-treq-worker)' 2>/dev/null || echo "  Not found"

.PHONY: check-alerts
check-alerts: ## Check current alert status (all groups)
	@echo "Current Alerts Status:"
	@$(KC) kubectl exec -n default deployment/temporal-prometheus-server -c prometheus-server -- \
		wget -qO- "http://localhost:9090/api/v1/rules" 2>&1 | \
		jq -r '.data.groups[] | {name: .name, alerts: [.rules[] | {alert: .name, state: .state, severity: .labels.severity}]}'

.PHONY: check-targets
check-targets: ## Check all Prometheus scrape targets
	@echo "Prometheus Targets (worker + Temporal):"
	@$(KC) kubectl exec -n default deployment/temporal-prometheus-server -c prometheus-server -- \
		wget -qO- "http://localhost:9090/api/v1/targets" 2>&1 | \
		jq -r '.data.activeTargets[] | select(.labels.pod | test("worker|temporal")) | {pod: .labels.pod, health: .health, scrapeUrl: .scrapeUrl, lastScrape: .lastScrape}'

.PHONY: check-worker-annotations
check-worker-annotations: ## Check worker pod Prometheus annotations (SERVICE=forohtoo, default)
	@echo "$(SERVICE) Worker Pod Annotations:"
	@$(KC) kubectl get pod -l app=$(SERVICE)-worker -n default -o jsonpath='{.items[0].metadata.annotations}' 2>/dev/null | jq '.' || \
		$(KC) kubectl get pod -l app=$(SERVICE) -n default -o jsonpath='{.items[0].metadata.annotations}' 2>/dev/null | jq '.' || \
		echo "  No pods found for $(SERVICE)"

.PHONY: check-datasource
check-datasource: ## Check Grafana Prometheus datasource
	@echo "Grafana Datasources:"
	@curl -s -u admin:$$($(KC) kubectl get secret -n default temporal-grafana -o jsonpath="{.data.admin-password}" | base64 -d) \
		"http://localhost:3000/api/datasources" 2>/dev/null | \
		jq -r '.[] | select(.type == "prometheus") | {name: .name, uid: .uid, isDefault: .isDefault}' || \
		echo "Start Grafana port-forward first: make grafana CLUSTER=$(CLUSTER)"

# --- Grafana Management ---

.PHONY: import-dashboard
import-dashboard: ## Import a single dashboard (FILE=grafana/forohtoo-workflows.json, default)
	$(eval FILE ?= grafana/forohtoo-workflows.json)
	@echo "Importing $(FILE)..."
	@curl -s -X POST -H "Content-Type: application/json" \
		-u admin:$$($(KC) kubectl get secret -n default temporal-grafana -o jsonpath="{.data.admin-password}" | base64 -d) \
		"http://localhost:3000/api/dashboards/db" \
		-d @$(FILE) | jq -r '.status, .url' || \
		echo "Start Grafana port-forward first: make grafana CLUSTER=$(CLUSTER)"

.PHONY: import-all-dashboards
import-all-dashboards: ## Import all Grafana dashboards
	@echo "Importing all dashboards..."
	@for f in grafana/*.json; do \
		case $$f in *-exported.json) continue;; esac; \
		echo "Importing $$f..."; \
		curl -s -X POST -H "Content-Type: application/json" \
			-u admin:$$($(KC) kubectl get secret -n default temporal-grafana -o jsonpath="{.data.admin-password}" | base64 -d) \
			"http://localhost:3000/api/dashboards/db" \
			-d @$$f | jq -r '"  " + .status + " " + (.url // "")' || echo "  Failed"; \
	done
	@echo "All dashboards imported"

.PHONY: list-dashboards
list-dashboards: ## List all Grafana dashboards
	@echo "Grafana Dashboards:"
	@curl -s -u admin:$$($(KC) kubectl get secret -n default temporal-grafana -o jsonpath="{.data.admin-password}" | base64 -d) \
		"http://localhost:3000/api/search" 2>/dev/null | \
		jq -r '.[] | "\(.title) - http://localhost:3000\(.url)"' || \
		echo "Start Grafana port-forward first: make grafana CLUSTER=$(CLUSTER)"

.PHONY: export-dashboard
export-dashboard: ## Export forohtoo dashboard from Grafana
	@echo "Exporting dashboard..."
	@curl -s -u admin:$$($(KC) kubectl get secret -n default temporal-grafana -o jsonpath="{.data.admin-password}" | base64 -d) \
		"http://localhost:3000/api/dashboards/uid/ffda71shyzvggb" 2>/dev/null | \
		jq '.dashboard' > grafana/forohtoo-workflows-exported.json && \
		echo "Exported to grafana/forohtoo-workflows-exported.json" || \
		echo "Start Grafana port-forward first: make grafana CLUSTER=$(CLUSTER)"

# --- Logs ---

.PHONY: logs-prometheus
logs-prometheus: ## Tail Prometheus logs
	@$(KC) kubectl logs -n default -f deployment/temporal-prometheus-server -c prometheus-server

.PHONY: logs-grafana
logs-grafana: ## Tail Grafana logs
	@$(KC) kubectl logs -n default -f deployment/temporal-grafana

.PHONY: logs-alertmanager
logs-alertmanager: ## Tail AlertManager logs
	@$(KC) kubectl logs -n default -f statefulset/temporal-alertmanager -c alertmanager

.PHONY: logs-worker
logs-worker: ## Tail worker logs (SERVICE=forohtoo, default)
	@$(KC) kubectl logs -n default -f -l app=$(SERVICE)-worker 2>/dev/null || \
		$(KC) kubectl logs -n default -f -l app=$(SERVICE) 2>/dev/null || \
		echo "No pods found for $(SERVICE)"

# --- Development ---

.PHONY: test-alerts
test-alerts: ## Validate alert rule syntax
	@echo "Validating alert rules..."
	@docker run --rm -v $$(pwd)/$(CLUSTER)/monitoring/alerts:/rules prom/prometheus:latest promtool check rules /rules/*.yaml || \
		echo "Install promtool to validate locally"

.PHONY: query
query: ## Run PromQL query (usage: make query QUERY='up')
	@$(KC) kubectl exec -n default deployment/temporal-prometheus-server -c prometheus-server -- \
		wget -qO- "http://localhost:9090/api/v1/query?query=$$(echo '$(QUERY)' | sed 's/ /%20/g')" 2>&1 | jq -r '.data.result'

# --- Cleanup ---

.PHONY: delete-alerts
delete-alerts: ## Remove all custom alert rules from Prometheus
	@echo "Removing alert rules..."
	@$(KC) kubectl get configmap temporal-prometheus-server -n default -o json | \
		jq 'del(.data."worker-alerts.yaml") | del(.data."temporal-server-alerts.yaml")' | $(KC) kubectl apply -f -
	@echo "Alert rules removed. Run 'make reload-prometheus CLUSTER=$(CLUSTER)' to apply"

.PHONY: delete-services
delete-services: ## Delete all worker metrics services
	@$(KC) kubectl delete -k $(CLUSTER)/monitoring/ 2>/dev/null || echo "Services not found"
