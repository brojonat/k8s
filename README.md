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

## Secrets

Secret templates (`*.yaml.tmpl`) have placeholder values (`FIXME`).
Real secret files are gitignored. Infrastructure secrets (Temporal DB
password, Tailscale OAuth) are read from `.env` by the Makefile.

## Adding a New Cluster

1. Create `<cluster-name>/kubeconfig` (will be gitignored)
2. Copy directory structure: `cp -r firekeeper/infra <cluster-name>/infra`
3. Adapt helm values for the new cluster
4. Deploy: `make apply-infra CLUSTER=<cluster-name>`
