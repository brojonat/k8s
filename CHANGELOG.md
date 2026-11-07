# Changelog

All notable changes to this repo and the clusters it manages. Newest first.
Format: [Keep a Changelog](https://keepachangelog.com/).

## 2026-11-07

Recovery from the firekeeper outage (2026-11-06 23:57 UTC to 2026-11-07 06:17 UTC,
about 6h20m; all public sites down).

### Added
- `firekeeper/infra/k3s/config.yaml`: kubelet `system-reserved=memory=1Gi`,
  `eviction-hard` with `memory.available<500Mi`, and matching
  `eviction-minimum-reclaim`. Applied on the host; allocatable memory is now
  ~6.08 GiB and the `kubepods` cgroup is capped at ~6.57 GiB.
- Tailscale `expose`/`hostname` annotations for `temporal-web` and
  `temporal-grafana` in `firekeeper/infra/temporal/helm-values.yaml`, so Temporal
  upgrades can't orphan the tailnet proxies.
- README sections on node protection, tailnet-only services, and debugging an
  unresponsive node. `TODO.md`, `CHANGELOG.md`, `LEARNINGS.md`.

### Changed
- Tailscale on the firekeeper host: 1.94.2 → 1.104.5.
- Tailscale operator chart and proxies: 1.94.2 → 1.104.4 (Helm revision 2).
- `temporal/temporal-grafana` Service re-annotated live; its proxy had been
  orphaned and stuck on 1.94.2.

### Fixed
- firekeeper hung by memory thrashing (no swap, no kubelet memory eviction).
  Hard reset via `hcloud server reset`. No evidence of an attack: traffic fell
  to zero rather than spiking, and there were no unknown logins, keys,
  accounts, or persistence changes.
