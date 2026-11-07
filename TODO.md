# TODO

## firekeeper

- [ ] Enable Hetzner backups for firekeeper (currently disabled; all data is on the one local disk)
- [ ] Find the trigger of the 2026-11-06 23:57 UTC hang (memory thrash, cause unknown; 2 GiB was available a minute before)
- [ ] Alert on node memory (MemAvailable, PSI) and site health; nothing paged during the 6h outage
- [ ] kalshi-real-time: analytics-sink and bayes-worker hit their 1Gi limits ~daily (all 27 OOM events Oct 24–Nov 6); PyTensor compile cache lives in the container fs, so each restart recompiles
- [ ] Traefik reached ~2 GB RSS in a global OOM on 2026-09-14 (normally ~50 MiB); find out why
- [ ] Add memory limits to the 36 containers without one; app ones belong in their app repos (brojonat-hugo, deadman-*, diddlylift-backend/frontend, five-cut-method, poisson-confidence-intervals), infra ones in Helm values (traefik, temporal, prometheus, grafana, nats, cert-manager, tailscale operator)
- [ ] Memory requests are 81% of allocatable after node protection; nhtsa-build (1Gi) + iybi-email-agent can briefly not fit at 12:00 UTC (delayed 15s on 2026-11-07)
- [ ] Keep Tailscale current: host had auto-update apply off and sat on 1.94.2 for months (`tailscale set --auto-update`, or schedule operator upgrades)
- [ ] Harden SSH: constant root brute-force on public :22; confirm password auth is off, consider restricting :22 in firekeeper-fw to the tailnet
- [ ] Verify cost: README says ~$15/mo, Hetzner API lists cpx31 at $62.49/mo in US locations
- [ ] Low priority: affiliate-bounty-board-workers (1,809) and gip-worker (1,584) have large historical restart counts; not restarting as of 2026-11-06

## Repo

- [ ] Convert Makefile to mise.toml (per conventions), including an `apply-k3s-config` task
