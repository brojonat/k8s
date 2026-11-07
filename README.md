# kube-clusters

Kubernetes cluster configuration and infrastructure management.

## Clusters

| Cluster      | Provider    | Nodes | Ingress | Cost     | Status |
| ------------ | ----------- | ----- | ------- | -------- | ------ |
| `firekeeper` | Hetzner K3s | 1     | traefik | ~$15/mo  | Active |

## Directory Structure

```
kube-clusters/
├── Makefile                    # Infrastructure + monitoring deploys
├── grafana/                    # Shared Grafana dashboards
├── <cluster>/
│   ├── kubeconfig              # Cluster credentials (gitignored)
│   ├── infra/                  # Infrastructure (Helm values)
│   │   ├── k3s/                # Host-level k3s config (/etc/rancher/k3s/config.yaml)
│   │   ├── cert-manager/
│   │   ├── nats/
│   │   ├── temporal/
│   │   └── tailscale/
│   └── monitoring/             # Prometheus monitoring resources
│       ├── kustomization.yaml
│       ├── workers/            # Metrics services
│       ├── patches/            # Deployment patches
│       └── alerts/             # Prometheus alert rules
```

## Quick Start

Use [k9s](https://k9scli.io/) for day-to-day cluster management:

```bash
KUBECONFIG=firekeeper/kubeconfig k9s
```

Useful k9s commands:
- `:deploy` — list deployments
- `:pods` — list pods
- `:svc` — list services
- `:secrets` — list secrets (press `x` to decode values)
- `:ingress` — list ingresses
- `:events` — cluster events
- `/` — filter by name

The Makefile handles things that are harder to do interactively:

```bash
# Deploy all infrastructure
make apply-infra

# Deploy individual components
make apply-cert-manager
make apply-nats
make apply-temporal
make apply-tailscale

# Apply monitoring (services, patches, alerts, reload prometheus)
make apply-monitoring

# Temporal admin (via admintools pod)
make temporal-namespaces
make temporal-schedules TEMPORAL_NS=forohtoo
make temporal-workflows TEMPORAL_NS=forohtoo
make temporal-create-ns TEMPORAL_NS=myapp
```

## Apps

| App                          | Deployments                | Has Ingress |
| ---------------------------- | -------------------------- | ----------- |
| affiliate-bounty-board       | backend, workers           | Yes         |
| brojonat-hugo                | 1                          | Yes         |
| deadman                      | backend, workers           | Yes         |
| diddlylift                   | backend, frontend, workers | Yes (x2)    |
| five-cut-method              | frontend                   | Yes         |
| forohtoo                     | server, worker             | Yes         |
| gip                          | api, worker                | Yes         |
| poisson-confidence-intervals | frontend                   | Yes         |

## Infrastructure

All infrastructure is Helm-managed. Values are in
`<cluster>/infra/<component>/helm-values.yaml`.

| Component    | Namespace    | Notes                  |
| ------------ | ------------ | ---------------------- |
| cert-manager | cert-manager | TLS via Let's Encrypt  |
| NATS         | nats         | Single replica         |
| Temporal     | temporal     | PlanetScale PostgreSQL |
| Tailscale    | tailscale    | Mesh networking        |

### Node protection (k3s host config)

`firekeeper/infra/k3s/config.yaml` reserves 1 GiB for the system and sets a
kubelet memory eviction threshold. Without it, k3s has no memory eviction and
the node can lock up instead of evicting pods (see `LEARNINGS.md`). It lives
on the host, not in Helm, so apply it by hand:

```bash
scp firekeeper/infra/k3s/config.yaml root@5.78.157.239:/etc/rancher/k3s/config.yaml
ssh root@5.78.157.239 'systemctl restart k3s'   # running containers stay up
# verify: allocatable should be ~1.5 GiB below capacity
KUBECONFIG=firekeeper/kubeconfig kubectl get node firekeeper \
  -o jsonpath='{.status.capacity.memory} -> {.status.allocatable.memory}'
```

### Tailnet-only services

Temporal UI and Grafana are exposed on the tailnet (not publicly) by the
Tailscale operator, via `tailscale.com/expose` annotations on their Services.
Those annotations are set in `firekeeper/infra/temporal/helm-values.yaml`; if
they go missing, the operator stops managing the proxy and it stops getting
upgrades.

| Hostname                       | Service                   |
| ------------------------------ | ------------------------- |
| `firekeeper-temporal-ui`       | `temporal/temporal-web`     |
| `firekeeper-temporal-grafana`  | `temporal/temporal-grafana` |

Host Tailscale is upgraded with apt; the operator and its proxies with
`helm upgrade tailscale-operator tailscale/tailscale-operator -n tailscale --reuse-values`.

## Debugging an unresponsive node

```bash
hcloud server metrics firekeeper --type cpu,disk,network \
  --start "$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ)" --end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" -o json
ssh -o ConnectTimeout=240 root@5.78.157.239          # thrashing boxes answer slowly
journalctl -b -1 -k | grep -i "killed process"       # previous boot's OOM kills
hcloud server reset firekeeper                       # hard reset, last resort
```

Prometheus (with node-exporter and cAdvisor history) is reachable through the
API server, no port-forward needed:

```bash
KUBECONFIG=firekeeper/kubeconfig kubectl get --raw \
  '/api/v1/namespaces/temporal/services/temporal-prometheus-server:80/proxy/api/v1/query?query=node_memory_MemAvailable_bytes'
```

## Secrets

Secret templates (`*.yaml.tmpl`) have placeholder values (`FIXME`).
Real secret files are gitignored. Infrastructure secrets (Temporal DB
password, Tailscale OAuth) are read from `.env` by the Makefile.

## Adding a New Cluster

1. Create `<cluster-name>/kubeconfig` (will be gitignored)
2. Copy directory structure: `cp -r firekeeper/infra <cluster-name>/infra`
3. Adapt helm values for the new cluster
4. Deploy: `make apply-infra CLUSTER=<cluster-name>`
