# Quick Reference Cheat Sheet

Essential commands for day-to-day monitoring operations. All commands accept `CLUSTER=<name>` (default: `do-sfo3-k8s-starter`).

## Quick Start

```bash
make apply-monitoring CLUSTER=do-sfo3-k8s-starter  # Apply everything (services, patches, alerts)
make all-uis CLUSTER=do-sfo3-k8s-starter            # Start all UIs at once
make print-grafana-creds CLUSTER=do-sfo3-k8s-starter # Get login info
make import-all-dashboards CLUSTER=do-sfo3-k8s-starter # Import all dashboards
```

## Credentials

```bash
make print-grafana-password    # Just the password
make print-grafana-creds       # Username + password
```

**Login:** admin / (password from command above)

## Access URLs

| Service | Command | URL |
|---------|---------|-----|
| Grafana | `make grafana` | http://localhost:3000 |
| Prometheus | `make prometheus` | http://localhost:9090 |
| AlertManager | `make alertmanager` | http://localhost:9093 |
| Worker Metrics | `make worker-metrics SERVICE=<name>` | http://localhost:9000/metrics |

## Dashboards

**All Workers (unified):**
- Import: `make import-all-dashboards`
- Select services from the `$service` dropdown to compare

**Forohtoo Workflows:**
- URL: http://localhost:3000/d/ffda71shyzvggb/forohtoo-workflows
- Shows: Activity execution times, rates, wallet count

**Temporal Server Health:**
- Shows: Latency, request rates, error rates, component status

**List all:**
```bash
make list-dashboards
```

## Alerts

```bash
make check-alerts       # View all alert groups
make apply-alerts       # Apply alert rules
make reload-prometheus  # Activate new rules
make test-alerts        # Validate rule syntax
```

## Status Checks

```bash
make monitoring-status  # Monitoring system status (all workers)
make check-targets      # All Prometheus scrape targets
make check-storage      # Disk usage
```

## Logs

```bash
make logs-prometheus    # Prometheus logs
make logs-grafana       # Grafana logs
make logs-alertmanager  # AlertManager logs
make logs-worker SERVICE=forohtoo    # Worker logs (any service)
make logs-worker SERVICE=deadman
```

## Management

```bash
make reload-prometheus   # Reload config (soft)
make restart-prometheus  # Restart pod (hard)
make stop-all           # Stop all port-forwards
```

## Apply Resources

```bash
make apply-services     # All worker metrics services (Kustomize)
make apply-patches      # All deployment patches
make apply-alerts       # All alert rules
make apply-monitoring   # Everything above
```

## Grafana

```bash
make import-all-dashboards   # Import all dashboards
make import-dashboard FILE=grafana/all-workers.json  # Specific dashboard
make export-dashboard        # Export forohtoo dashboard
```

## Troubleshooting

```bash
make check-worker-annotations SERVICE=deadman  # Verify Prometheus annotations
make check-datasource         # Verify Grafana -> Prometheus connection
make check-targets            # See scrape health for all workers
```

**Common fixes:**
```bash
# Dashboard not loading
make grafana
make import-all-dashboards

# Metrics not showing for a specific worker
make check-targets
make worker-metrics SERVICE=gip

# Alerts not working
make apply-alerts
make reload-prometheus
make check-alerts
```

## Documentation

Read files directly:
- **README.md** - Overview & quick start
- **docs/DETAILED-GUIDE.md** - Complete documentation
- **docs/TROUBLESHOOTING.md** - Common issues

## Useful PromQL Queries

**Activity p95 latency (all services):**
```promql
histogram_quantile(0.95, sum by (service, activity, le) (rate(poll_activity_duration_seconds_bucket[5m])))
```

**Execution rate per minute, by service:**
```promql
sum by (service, activity) (rate(poll_activity_duration_seconds_count[5m])) * 60
```

**Total executions (last hour), by service:**
```promql
sum by (service) (increase(poll_activity_duration_seconds_count[1h]))
```

**Temporal schedule-to-start latency:**
```promql
histogram_quantile(0.95, sum by (task_queue, le) (rate(temporal_server_schedule_to_start_latency_bucket[5m])))
```

## Common Workflows

### First Time Setup

```bash
# 1. Apply all resources
make apply-monitoring CLUSTER=do-sfo3-k8s-starter

# 2. Start UIs
make all-uis CLUSTER=do-sfo3-k8s-starter

# 3. Get Grafana password
make print-grafana-password

# 4. Import dashboards
make import-all-dashboards

# 5. Browse dashboards
open http://localhost:3000
```

### Daily Operations

```bash
# Check if everything is healthy
make monitoring-status

# View metrics (unified dashboard)
make grafana

# Check for firing alerts
make check-alerts
```

### After Config Changes

```bash
# Alert rules changed
make apply-alerts
make reload-prometheus

# Dashboards changed
make import-all-dashboards

# Worker deployment changed
kubectl rollout restart deployment <name> -n default
# Wait 2 minutes for Prometheus to rediscover
```

### Adding a New Worker

1. Copy `<cluster>/monitoring/workers/forohtoo.yaml` -> `<cluster>/monitoring/workers/my-service.yaml`
2. Copy `<cluster>/monitoring/patches/forohtoo.yaml` -> `<cluster>/monitoring/patches/my-service.yaml`
3. Update names and selectors in both files
4. Add to `<cluster>/monitoring/kustomization.yaml`
5. Run `make apply-services && make apply-patches && make reload-prometheus`
6. Dashboards auto-discover - no changes needed

## Key Files

| File | Purpose |
|------|---------|
| `Makefile` | All commands (cluster + monitoring) |
| `<cluster>/monitoring/kustomization.yaml` | Kustomize manifest (all worker services) |
| `<cluster>/monitoring/workers/*.yaml` | Metrics services per worker |
| `<cluster>/monitoring/patches/*.yaml` | Deployment patches per worker |
| `<cluster>/monitoring/alerts/worker-alerts.yaml` | Worker activity alerts |
| `<cluster>/monitoring/alerts/temporal-server-alerts.yaml` | Temporal server alerts |
| `grafana/all-workers.json` | Unified worker dashboard |
| `grafana/temporal-server.json` | Temporal server dashboard |
| `grafana/forohtoo-workflows.json` | Original forohtoo dashboard |

---

Run `make help` anytime to see all available commands.
