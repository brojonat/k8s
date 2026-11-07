# Monitoring Troubleshooting Guide

Common issues and solutions for Temporal & Application monitoring.

---

## Table of Contents

- [Node Networking Issues](#node-networking-issues) — **check this first**
- [Grafana Issues](#grafana-issues)
- [Prometheus Issues](#prometheus-issues)
- [AlertManager Issues](#alertmanager-issues)
- [Worker Metrics Issues](#worker-metrics-issues)
- [Dashboard Issues](#dashboard-issues)
- [Storage Issues](#storage-issues)

---

## Node Networking Issues

> **Check this first.** A node-level network failure presents as a dozen
> unrelated-looking monitoring failures at once. If *many* components broke
> simultaneously, suspect the node before debugging any single component.

### Many pods CrashLooping at once / "server misbehaving" / "no such host"

**Symptom:** Several unrelated things fail together, e.g.

- `temporal-history` CrashLoopBackOff with
  `sql schema version compatibility check failed: ... no usable database connection found`
  and `lookup us-west-2.pg.psdb.cloud on 10.43.0.10:53: server misbehaving`
- Temporal workers CrashLooping on `--check-connection` liveness probes
- CoreDNS logs full of `i/o timeout` to upstream resolvers (1.1.1.1, 185.12.64.2)
- `cert-manager-cainjector` CrashLooping
- `kubectl top` fails with `Metrics API not available`
- CronJob pods all `Error`

**Cause:** The node lost its IPv4 address. On Hetzner, `eth0` gets its IPv4 via
DHCP (lease `LIFETIME=1d`, renew every 12h) while IPv6 is configured *statically*
in `/etc/netplan/50-cloud-init.yaml`. If systemd-networkd fails to install the
DHCPv4 route during renewal it marks the link `failed` **and never retries**:

```
eth0: Could not set DHCPv4 route: Connection timed out
eth0: Failed
```

IPv6 keeps working, so Tailscale and `kubectl` still work — which is why the node
looks `Ready` and the problem masquerades as many application failures.

Note the feedback loop: CrashLooping pods churn veth interfaces constantly, which
floods netlink and can itself cause the route-install timeout.

**Diagnose:**

```bash
# Internal DNS works but external does not => node egress, not a CoreDNS bug
kubectl -n nats exec deploy/nats-box -- nslookup kubernetes.default.svc.cluster.local
kubectl -n nats exec deploy/nats-box -- nslookup google.com

# Is it DNS, or all egress? If raw TCP fails too, it is not DNS.
kubectl -n nats exec deploy/nats-box -- nc -z -w3 1.1.1.1 443
```

Then inspect the host itself with a privileged hostNetwork pod:

```bash
kubectl run hostdbg --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"hostNetwork":true,"containers":[{"name":"hostdbg",
"image":"busybox:1.36","securityContext":{"privileged":true},
"command":["sleep","3600"],"volumeMounts":[{"name":"h","mountPath":"/host"}]}],
"volumes":[{"name":"h","hostPath":{"path":"/"}}]}}'

# eth0 should have an `inet` line. If only `inet6`, IPv4 is gone.
kubectl exec hostdbg -- ip addr show eth0
kubectl exec hostdbg -- ip -4 route show          # expect a default route

# Confirms the cause: ADMIN_STATE=failed / IPV4_ADDRESS_STATE=off
kubectl exec hostdbg -- cat /host/run/systemd/netif/links/2
kubectl exec hostdbg -- cat /host/run/systemd/netif/leases/2   # ADDRESS= and ROUTER=
kubectl exec hostdbg -- sh -c \
  'chroot /host journalctl -u systemd-networkd --since "14 days ago" \
   | grep -viE "veth|cni0|flannel" | tail -30'
```

**Fix (non-disruptive).** Re-add the address and route from the saved lease.
This is purely additive, does not touch IPv6, and will not drop your Tailscale
session. Use the `ADDRESS=` / `ROUTER=` values from the lease file:

```bash
kubectl exec hostdbg -- sh -c '
  ip addr  add 5.78.157.239/32 dev eth0
  ip route add 172.31.1.1/32   dev eth0
  ip route add default via 172.31.1.1 dev eth0'

# Verify host, then pod, egress
kubectl exec hostdbg -- ping -c2 1.1.1.1
kubectl -n nats exec deploy/nats-box -- nslookup us-west-2.pg.psdb.cloud
```

Then reset the CrashLoop backoff timers so recovery is immediate rather than
waiting out the 5-minute backoff:

```bash
kubectl -n temporal delete pod -l app.kubernetes.io/component=history
kubectl -n cert-manager delete pod -l app.kubernetes.io/component=cainjector
kubectl -n kube-system  delete pod -l k8s-app=metrics-server
kubectl delete pod --field-selector=status.phase==Failed -n default   # stale job pods

# Verify
kubectl -n temporal exec deploy/temporal-admintools -- temporal operator cluster health
kubectl top nodes
```

**Important — this fix is not durable.** A manual `ip addr add` is not managed by
systemd-networkd, so the DHCP lease is still not being renewed. A reboot
re-runs DHCP from scratch and should recover on its own, but to hand IPv4 back to
networkd you need:

```bash
networkctl reconfigure eth0      # or: systemctl restart systemd-networkd
```

Only do this **with Hetzner web-console access available** — it re-applies the
IPv6 config too, and if IPv6 drops you lose the Tailscale path and with it all
remote access to the box.

To stop this recurring, consider converting `eth0`'s IPv4 to a static address in
netplan (the Hetzner IP is permanently assigned anyway), removing the dependency
on DHCPv4 renewal succeeding.

---

## Grafana Issues

### Can't access Grafana

**Symptom:** http://localhost:3000 doesn't load

**Solutions:**

1. Check if port-forward is running:
   ```bash
   ps aux | grep "port-forward.*grafana"
   ```

2. Restart port-forward:
   ```bash
   make grafana
   ```

3. Check Grafana pod status:
   ```bash
   kubectl get pod -l app.kubernetes.io/name=grafana -n default
   ```

4. Check Grafana logs:
   ```bash
   make logs-grafana
   ```

---

### Wrong password / Can't login

**Solution:**

Get the correct password:
```bash
make print-grafana-password
```

Default username is always `admin`.

---

### Dashboard shows "No data"

**Possible causes:**

1. **Prometheus datasource not configured**
   ```bash
   make check-datasource
   ```
   Should show `TemporalMetrics` datasource.

2. **Worker metrics not being scraped**
   ```bash
   make check-targets
   ```
   Should show forohtoo-worker pod with `health: "up"`.

3. **Time range too narrow**
   - Check dashboard time picker (top right)
   - Set to "Last 1 hour" or "Last 6 hours"

4. **No activity has executed yet**
   - Wait for workflows to execute
   - Check worker logs: `make logs-worker`

---

### Can't import dashboard

**Symptom:** `make import-dashboard` fails

**Solutions:**

1. Ensure Grafana port-forward is running:
   ```bash
   make grafana
   ```

2. Check if dashboard JSON is valid:
   ```bash
   cat grafana/forohtoo-workflows.json | jq .
   ```

3. Import manually:
   - Visit http://localhost:3000
   - Click "+" → "Import"
   - Upload `grafana/forohtoo-workflows.json`

---

## Prometheus Issues

### Prometheus not scraping worker metrics

**Symptom:** `make check-targets` shows no forohtoo-worker

**Solutions:**

1. **Check worker pod annotations:**
   ```bash
   make check-worker-annotations
   ```

   Should show:
   ```json
   {
     "prometheus.io/scrape": "true",
     "prometheus.io/port": "9000",
     "prometheus.io/path": "/metrics"
   }
   ```

2. **If annotations missing, apply patch:**
   ```bash
   kubectl patch deployment forohtoo-worker -n default --patch-file k8s/worker-deployment-patch.yaml
   ```

3. **Check worker metrics service:**
   ```bash
   kubectl get svc forohtoo-worker-metrics -n default
   ```

   If not found:
   ```bash
   make apply-service
   ```

4. **Wait for Prometheus to discover:**
   - Prometheus scrapes every 60 seconds
   - Wait 1-2 minutes after applying changes

5. **Check Prometheus config:**
   ```bash
   make show-prometheus-config | grep -A5 "kubernetes-pods"
   ```

---

### Alert rules not loading

**Symptom:** `make check-alerts` shows empty or missing forohtoo_workflows

**Solutions:**

1. **Check if alert rules exist in ConfigMap:**
   ```bash
   kubectl get configmap temporal-prometheus-server -n default -o jsonpath='{.data}' | jq 'keys[]' | grep forohtoo
   ```

   Should show: `forohtoo_alerts.yml`

2. **Check if prometheus.yml references alert file:**
   ```bash
   make show-prometheus-config | grep -A10 "rule_files:"
   ```

   Should include: `- /etc/config/forohtoo_alerts.yml`

3. **Apply alert rules:**
   ```bash
   make apply-alerts
   make reload-prometheus
   ```

4. **Check Prometheus logs for errors:**
   ```bash
   make logs-prometheus | grep -i error
   ```

5. **If still not working, restart Prometheus:**
   ```bash
   make restart-prometheus
   ```

---

### Queries return no data

**Symptom:** PromQL queries return empty results

**Solutions:**

1. **Check if metrics exist:**
   ```bash
   kubectl exec -n default deployment/temporal-prometheus-server -c prometheus-server -- \
     wget -qO- "http://localhost:9090/api/v1/label/__name__/values" | \
     jq -r '.data[]' | grep poll_activity
   ```

2. **Check scrape targets:**
   ```bash
   make check-targets
   ```

3. **Verify worker is exposing metrics:**
   ```bash
   make worker-metrics
   curl http://localhost:9000/metrics | grep poll_activity
   ```

4. **Wait for data to accumulate:**
   - Metrics need time to be scraped
   - Wait 1-2 minutes after worker starts

---

## AlertManager Issues

### Alerts not showing in AlertManager

**Symptom:** AlertManager UI is empty

**Possible causes:**

1. **No alerts are firing:**
   ```bash
   make check-alerts
   ```
   Check alert states. May all be "inactive".

2. **AlertManager not receiving alerts from Prometheus:**
   ```bash
   kubectl logs -n default deployment/temporal-prometheus-server -c prometheus-server | grep alertmanager
   ```

3. **AlertManager not running:**
   ```bash
   kubectl get pod -l app.kubernetes.io/name=alertmanager -n default
   ```

---

### Alerts firing but no notifications

**Symptom:** Alerts show in AlertManager but no Slack/email

**Solution:**

AlertManager notifications are not configured by default. See [DETAILED-GUIDE.md](./DETAILED-GUIDE.md#alertmanager-notifications) for:
- Slack integration
- Email setup
- Webhook configuration

---

## Worker Metrics Issues

### Worker metrics endpoint returns 404

**Symptom:** `curl http://localhost:9000/metrics` returns 404

**Solutions:**

1. **Check if metrics server is running:**
   ```bash
   make logs-worker | grep "metrics HTTP server"
   ```

   Should show: `"starting metrics HTTP server","addr":":9000"`

2. **Check if port 9000 is correct:**
   ```bash
   make logs-worker | grep METRICS_ADDR
   ```

3. **Check worker deployment:**
   ```bash
   kubectl get deployment forohtoo-worker -n default -o yaml | grep -A5 "containerPort"
   ```

   Should include:
   ```yaml
   - name: metrics
     containerPort: 9000
   ```

---

### Metrics show but are stale

**Symptom:** Metrics don't update

**Solutions:**

1. **Check Prometheus scrape interval:**
   Default is 60 seconds. Wait at least 1 minute.

2. **Check last scrape time:**
   ```bash
   make check-targets
   ```
   Look at `lastScrape` field.

3. **Check if worker is stuck:**
   ```bash
   make logs-worker
   ```

---

## Dashboard Issues

### Panels show "N/A" or empty

**Possible causes:**

1. **No data in time range:**
   - Adjust time picker (top right)
   - Try "Last 6 hours" or "Last 24 hours"

2. **Query error:**
   - Click panel title → Edit
   - Check for red error messages
   - Verify PromQL syntax

3. **Data doesn't exist yet:**
   - Activities may not have executed
   - Check: `make logs-worker`

---

### Graph shows only one data point

**Cause:** Not enough time has passed

**Solution:** Wait 5-10 minutes for more data points to accumulate, or adjust time range.

---

### Table shows wrong columns

**Solution:**

1. Edit panel
2. Check "Transformations" tab
3. Verify "Organize" transformation
4. Re-map columns if needed

---

## Storage Issues

### Prometheus storage full

**Symptom:** Prometheus crashes or stops scraping

**Solutions:**

1. **Check current usage:**
   ```bash
   make check-storage
   ```

2. **If > 90% full, reduce retention:**
   ```bash
   kubectl edit deployment temporal-prometheus-server -n default
   ```

   Update:
   ```yaml
   args:
   - --storage.tsdb.retention.time=7d  # Reduce from 15d to 7d
   ```

3. **Or increase storage:**
   ```bash
   kubectl edit pvc temporal-prometheus-server -n default
   ```

   Update:
   ```yaml
   spec:
     resources:
       requests:
         storage: 16Gi  # Increase from 8Gi
   ```

4. **Compact storage:**
   ```bash
   make restart-prometheus
   ```

---

### Out of disk space

**Prevention:**

Prometheus auto-deletes data after 15 days. If you're still running out:

1. Check for other apps using disk
2. Increase PVC size (see above)
3. Reduce retention period
4. Delete old time series:
   ```bash
   kubectl exec -n default deployment/temporal-prometheus-server -c prometheus-server -- \
     rm -rf /data/wal
   make restart-prometheus
   ```

---

## General Debugging

### Get full system status

```bash
make status
```

Shows status of all monitoring components.

---

### Check all port-forwards

```bash
ps aux | grep "kubectl port-forward"
```

Kill all and restart:
```bash
make stop-all
make all-uis
```

---

### Verify end-to-end flow

1. **Worker exposes metrics:**
   ```bash
   make worker-metrics
   curl http://localhost:9000/metrics | head -20
   ```

2. **Prometheus scrapes worker:**
   ```bash
   make check-targets | grep forohtoo
   ```

3. **Metrics queryable in Prometheus:**
   ```bash
   make prometheus
   # Visit http://localhost:9090/graph
   # Query: poll_activity_duration_seconds_count
   ```

4. **Dashboard shows data:**
   ```bash
   make grafana
   # Visit http://localhost:3000/d/ffda71shyzvggb/forohtoo-workflows
   ```

---

## Still Having Issues?

### Collect debug info:

```bash
# System status
make status > debug-status.txt

# Check targets
make check-targets > debug-targets.txt

# Prometheus config
make show-prometheus-config > debug-config.txt

# Recent logs
make logs-prometheus > debug-prometheus-logs.txt 2>&1 &
sleep 10
pkill -f "kubectl logs.*prometheus"

make logs-worker > debug-worker-logs.txt 2>&1 &
sleep 10
pkill -f "kubectl logs.*worker"
```

Then review the `debug-*.txt` files for errors.

---

## Common Error Messages

### "context deadline exceeded"

**Cause:** Kubernetes API timeout

**Solution:** Retry command, check cluster connectivity

---

### "connection refused"

**Cause:** Port-forward not running or service not available

**Solution:**
1. Check if port-forward running: `ps aux | grep port-forward`
2. Restart: `make all-uis`
3. Check pod status: `make status`

---

### "no such host"

**Cause:** Service doesn't exist

**Solution:**
```bash
make apply-service
```

---

### "permission denied"

**Cause:** kubectl not configured or insufficient permissions

**Solution:**
1. Check kubeconfig: `kubectl config current-context`
2. Test access: `kubectl get pods -n default`

---

## Prevention

### Regular maintenance:

```bash
# Weekly: Check storage
make check-storage

# Monthly: Verify all components healthy
make status

# After config changes: Reload Prometheus
make reload-prometheus

# After significant changes: Restart Prometheus
make restart-prometheus
```

---

## Getting Help

If you're still stuck:

1. Check [DETAILED-GUIDE.md](./DETAILED-GUIDE.md) for complete documentation
2. Review Prometheus logs: `make logs-prometheus`
3. Review Grafana logs: `make logs-grafana`
4. Check Temporal Helm chart documentation
5. Search Grafana/Prometheus docs for specific error messages
