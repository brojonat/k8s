# kube-clusters

Multi-cluster Kubernetes configuration repo. Manages deployments across DigitalOcean and Hetzner clusters.

## Clusters

| Cluster | Provider | Nodes | Ingress | Cost |
|---------|----------|-------|---------|------|
| `do-sfo3-k8s-starter` | DigitalOcean Managed K8s | 4 | nginx | ~$110/mo |
| `hetzner-splinter2` | Hetzner K3s | 1 | traefik | ~$30/mo |

## Directory Structure

```
kube-clusters/
├── Makefile                    # Cluster ops + monitoring ops
├── QUICK-REFERENCE.md          # Monitoring command cheat sheet
├── scripts/
│   └── export-cluster.sh      # Export clean YAMLs from a running cluster
├── docs/
│   ├── DETAILED-GUIDE.md      # Comprehensive monitoring guide
│   └── TROUBLESHOOTING.md     # Common monitoring issues
├── grafana/                    # Shared Grafana dashboards (cluster-agnostic)
│   ├── all-workers.json
│   ├── forohtoo-workflows.json
│   └── temporal-server.json
├── <cluster>/
│   ├── kubeconfig              # Cluster credentials (gitignored)
│   ├── infra/                  # Infrastructure (Helm-managed)
│   │   ├── cert-manager/
│   │   ├── nats/
│   │   ├── temporal/
│   │   └── tailscale/
│   ├── apps/                   # Application deployments (kubectl apply)
│   │   ├── regcred.yaml.tmpl
│   │   └── <app-name>/
│   │       ├── deployment-*.yaml
│   │       ├── service-*.yaml
│   │       ├── ingress-*.yaml
│   │       └── secret-*.yaml.tmpl
│   └── monitoring/             # Prometheus/Grafana monitoring resources
│       ├── kustomization.yaml  # Kustomize: all worker metrics services
│       ├── workers/            # Metrics Service per worker (7 files)
│       ├── patches/            # Deployment patches per worker (8 files)
│       └── alerts/             # Prometheus alert rules (2 files)
```

## Quick Start

```bash
# Check cluster status
make status CLUSTER=do-sfo3-k8s-starter
make status CLUSTER=hetzner-splinter2

# Deploy infrastructure
make apply-infra CLUSTER=hetzner-splinter2

# Deploy a single app
make apply-app APP=brojonat-hugo CLUSTER=hetzner-splinter2

# Deploy all apps
make apply-apps CLUSTER=hetzner-splinter2

# Dry-run before applying
make dry-run-app APP=brojonat-hugo CLUSTER=hetzner-splinter2

# Diff DO vs Hetzner configs
make diff-clusters

# Verify migration
make verify-migration CLUSTER=hetzner-splinter2
```

## Apps (14 groups, 20 deployments)

| App | Deployments | Has Ingress | Notes |
|-----|------------|-------------|-------|
| affiliate-bounty-board | backend, workers | Yes | |
| brojonat-hugo | 1 | Yes | Static site |
| deadman | backend, workers | Yes | |
| diddlylift | backend, frontend, workers | Yes (x2) | |
| eth-notification | workers | Yes | Workers only, ingress for API |
| five-cut-method | frontend | Yes | Static frontend |
| forohtoo | server, worker | Yes | |
| gip | api, worker | Yes | |
| gredfin | backend | Yes | |
| kaggo | backend, treq-worker | Yes | |
| nats-box | 1 | No | NATS debug tool |
| poisson-confidence-intervals | frontend | Yes | Static frontend |
| realtor-rank | frontend | Yes | Static frontend |

## Secrets

Secret templates (`*.yaml.tmpl`) have keys but placeholder values (`FIXME`). To create real secrets:

1. Copy the template: `cp secret-foo.yaml.tmpl secret-foo.yaml`
2. Fill in actual values
3. Apply: `kubectl apply -f secret-foo.yaml`

Real secret files (`secret.yaml`, `secrets.yaml`) are gitignored.

## Infrastructure

All infrastructure is Helm-managed. Values are in `<cluster>/infra/<component>/helm-values.yaml`.

| Component | DO Namespace | Notes |
|-----------|-------------|-------|
| cert-manager | cert-manager | TLS via Let's Encrypt |
| NATS | default | 3 replicas on DO, 1 on Hetzner |
| Temporal | default | PostgreSQL at `5.78.109.232` (Hetzner) |
| Tailscale | tailscale | Mesh networking |

## Monitoring

Prometheus, Grafana, and AlertManager monitoring for Temporal workflows and all 7 application workers. Each cluster has its own monitoring resources under `<cluster>/monitoring/`; Grafana dashboards are shared at the repo root.

### Quick Start

```bash
# Apply all monitoring resources (services, patches, alerts)
make apply-monitoring CLUSTER=do-sfo3-k8s-starter

# Start monitoring UIs
make grafana CLUSTER=do-sfo3-k8s-starter
make prometheus CLUSTER=do-sfo3-k8s-starter

# Check monitoring health
make monitoring-status CLUSTER=do-sfo3-k8s-starter

# Import Grafana dashboards
make import-all-dashboards CLUSTER=do-sfo3-k8s-starter

# Get Grafana credentials
make print-grafana-creds CLUSTER=do-sfo3-k8s-starter
```

### Monitored Workers

| Worker | Deployment | Metrics Service |
|--------|-----------|----------------|
| forohtoo | `forohtoo-worker` | `forohtoo-worker-metrics` |
| affiliate-bounty-board | `affiliate-bounty-board-workers` | `abb-worker-metrics` |
| deadman | `deadman-workers` | `deadman-worker-metrics` |
| diddlylift | `diddlylift-workers` | `diddlylift-worker-metrics` |
| eth-notification | `eth-notification-workers` | `eth-notification-worker-metrics` |
| gip | `gip-worker` | `gip-worker-metrics` |
| kaggo-treq | `kaggo-treq-worker` | `kaggo-treq-worker-metrics` |

### Alert Rules

**Worker alerts** (`worker-alerts.yaml`): SlowActivityExecution, NoActivityExecutions, LowActivityExecutionRate, VerySlowActivityExecution

**Temporal server alerts** (`temporal-server-alerts.yaml`): HighScheduleToStartLatency, HighWorkflowTaskLatency, ServiceDown, PersistenceErrors

### Adding a New Worker

1. Create `<cluster>/monitoring/workers/my-service.yaml` (copy any existing)
2. Create `<cluster>/monitoring/patches/my-service.yaml` (copy any existing)
3. Add to `<cluster>/monitoring/kustomization.yaml`
4. Run `make apply-services && make apply-patches && make reload-prometheus`
5. Dashboards auto-discover via template variable — no dashboard changes needed

For full details see [`docs/DETAILED-GUIDE.md`](./docs/DETAILED-GUIDE.md), [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md), and [`QUICK-REFERENCE.md`](./QUICK-REFERENCE.md).

## Adding a New Cluster

1. Create `<cluster-name>/kubeconfig` (will be gitignored)
2. Copy directory structure from an existing cluster:
   ```bash
   cp -r do-sfo3-k8s-starter/infra <cluster-name>/infra
   cp -r do-sfo3-k8s-starter/apps <cluster-name>/apps
   ```
3. Adapt `infra/` configs for the new cluster's ingress controller and storage
4. Adapt `apps/` ingress YAML files for the ingress class
5. Test: `make status CLUSTER=<cluster-name>`
6. Deploy: `make apply-infra CLUSTER=<cluster-name>`

---

## Migration Runbook: DO → Hetzner

### Prerequisites

- Hetzner node running K3s with Traefik ingress
- Tailscale installed for mesh networking
- PostgreSQL already on Hetzner (`5.78.109.232`) — database does NOT move
- Firewall allows ports 80/443 for Let's Encrypt HTTP-01 challenges

### Phase 1: Infrastructure

Deploy in order (dependencies matter):

```bash
make apply-cert-manager CLUSTER=hetzner-splinter2
make apply-nats CLUSTER=hetzner-splinter2
# Do NOT deploy Temporal yet — see Phase 4
make apply-tailscale CLUSTER=hetzner-splinter2
```

### Phase 2: Deploy Apps by Tier

**Tier 1 — Static frontends (lowest risk):**
- brojonat-hugo
- five-cut-method
- poisson-confidence-intervals
- realtor-rank

```bash
for app in brojonat-hugo five-cut-method poisson-confidence-intervals realtor-rank; do
  make apply-app APP=$app CLUSTER=hetzner-splinter2
done
```

**Tier 2 — Simple backends:**
- gip
- gredfin
- forohtoo
- eth-notification

**Tier 3 — Complex apps:**
- affiliate-bounty-board
- deadman
- diddlylift
- kaggo
- nats-box

### Phase 3: Per-App Cutover

For each app:

1. Apply secrets on Hetzner (fill in `*.yaml.tmpl` → `*.yaml`, apply)
2. Apply app YAMLs: `make apply-app APP=<name> CLUSTER=hetzner-splinter2`
3. Verify pods running: `kubectl get pods -l app=<name>`
4. Update DNS: A record from DO LB (`24.199.72.98`) → Hetzner node (`5.78.94.179`)
5. Verify TLS cert issued: `kubectl get certificates`
6. Test the app at its domain
7. Delete from DO: `kubectl delete -f do-sfo3-k8s-starter/apps/<name>/`

**DNS tip:** Set TTL to 300s (5 min) before migration for faster propagation.

### Phase 4: Temporal Cutover

Temporal is special — both clusters connect to the same PostgreSQL. **Never run Temporal on both clusters simultaneously.**

```bash
# 1. Scale down Temporal on DO
KUBECONFIG=do-sfo3-k8s-starter/kubeconfig kubectl scale deployment \
  temporal-frontend temporal-history temporal-matching temporal-worker \
  -n default --replicas=0

# 2. Deploy Temporal on Hetzner
make apply-temporal CLUSTER=hetzner-splinter2

# 3. Verify Temporal is healthy on Hetzner
KUBECONFIG=hetzner-splinter2/kubeconfig kubectl get pods -l app.kubernetes.io/instance=temporal
```

### Phase 5: DNS Migration

Update all A records:

| Domain | Old IP (DO LB) | New IP (Hetzner) |
|--------|----------------|------------------|
| brojonat.com | 24.199.72.98 | 5.78.94.179 |
| *.brojonat.com | 24.199.72.98 | 5.78.94.179 |
| incentivizethis.com | 24.199.72.98 | 5.78.94.179 |
| diddlylift.com | 24.199.72.98 | 5.78.94.179 |
| if-i-go-missing.com | 24.199.72.98 | 5.78.94.179 |

### Phase 6: Decommission DO

After monitoring period (recommend 1-2 weeks):

1. Verify all apps responding on Hetzner
2. Verify no traffic hitting DO cluster
3. Delete DO Kubernetes cluster
4. Cancel DO subscription

### Risks

| Risk | Mitigation |
|------|------------|
| Temporal dual-write to same Postgres | Never run Temporal on both clusters simultaneously |
| TLS cert issuance failure on Hetzner | Verify firewall allows ports 80/443 for HTTP-01 challenges |
| Resource exhaustion on single Hetzner node | Monitor closely; upgrade node size if needed |
| NATS data starts empty on Hetzner | Drain important JetStream streams before cutover |
