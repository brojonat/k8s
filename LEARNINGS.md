# Learnings

Hard-won knowledge. Each entry: what happened, why it was surprising, how to
avoid it.

## k3s ships with no kubelet memory eviction

**What happened:** On 2026-11-06 firekeeper hung for 6 hours. The kernel still
answered ping and accepted TCP, but SSH timed out at the banner and every site
hung. Hetzner metrics showed ~1.5 GB/s of disk *reads*, near-zero writes,
240–320% CPU, and network falling to zero: the node was thrashing, evicting and
re-reading executable pages. There was no swap.

**Why it was surprising:** You'd expect Kubernetes to evict pods before the
node dies. But k3s passes `eviction-hard` with only `imagefs`/`nodefs`
signals, which replaces the kubelet default that includes `memory.available`,
and it sets no `system-reserved`. So nothing evicted pods, and the pod cgroup
could use all of RAM, starving k3s, sshd, and journald.

**How to avoid:** Keep `firekeeper/infra/k3s/config.yaml` applied on every
k3s node. Verify with
`kubectl get --raw /api/v1/nodes/<node>/proxy/configz | jq .kubeletconfig.evictionHard`.

## Setting `eviction-hard` replaces the whole map

**What happened:** Adding `memory.available<500Mi` alone would have silently
dropped the `nodefs`/`imagefs` thresholds k3s had set.

**Why it was surprising:** It looks like an additive setting.

**How to avoid:** List every signal you want in `eviction-hard` and
`eviction-minimum-reclaim`.

## Allocatable lags a k3s restart by a few seconds

**What happened:** Right after `systemctl restart k3s` and the node going
Ready, `allocatable` and `kubepods.slice/memory.max` still showed full
capacity. Twenty seconds later both were correct.

**How to avoid:** Re-check before concluding the config didn't apply.

## Tailscale proxies can be silently orphaned

**What happened:** After the operator was upgraded, the Temporal UI proxy
updated but the Grafana proxy stayed on 1.94.2. Restarting the operator didn't
help. The `temporal-grafana` Service had lost its `tailscale.com/expose`
annotation and finalizer, so the operator no longer owned the proxy. The proxy
kept running unpatched. A Temporal Helm upgrade is the likely culprit (the
annotations weren't in Helm values), but that wasn't confirmed.

**How to avoid:** Put operator annotations in Helm values, not just
`kubectl annotate`. If one proxy won't upgrade, compare its parent Service's
annotations with a working one.

## Memory thrash vs DoS in Hetzner metrics

**What happened:** The first instinct was "we're being DoS'd".

**How to tell:** A flood shows inbound bytes and pps spiking. Thrashing shows
inbound traffic *dropping* to ~0, disk reads in GB/s with few writes, and high
CPU (in-kernel reclaim). Pull 30s-step metrics around the onset with
`hcloud server metrics --type cpu,disk,network`.

## `journalctl -k` only reads the current boot

**What happened:** A `--since` query for OOM kills from before a reboot came
back empty.

**How to avoid:** Use `journalctl -b -1 -k` for the previous boot. Full-journal
greps on this host are slow (90s+), so narrow with `--since`/`--until`.

## Agent shell gotchas on this machine

- The shell is zsh: `KC="kubectl --kubeconfig x"; $KC get pods` fails because
  zsh doesn't word-split variables. Use a function instead.
- `k` is already an alias, so `k(){ ... }` fails to parse. Pick another name.
