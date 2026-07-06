![SafeCloud.PRO](../docs/assets/wm-white.png)

# Monitoring — Sandboxed Telemetry & Scheduled Security Sweeps

Host observability for the hardened stack, delivered with the same least-privilege discipline as the services it watches.

## Files

| File | Deploys to | Purpose |
| :--- | :--- | :--- |
| `prometheus-node-exporter.service` | `/etc/systemd/system/` | Hardened, sandboxed systemd unit for the node exporter |
| `safecloud-sentinel.cron` | `/etc/cron.d/safecloud-sentinel` | Hourly AppArmor-denial sweep + service health alerting |
| `prometheus-alerts.yml` | Prometheus server `rule_files:` | 8 alerting rules (exporter down, CPU/load/memory, disk-fill, reboot) |
| `grafana-dashboard.json` | Grafana → Import | Host dashboard: CPU, memory, load, disk, network, uptime |
| `logrotate-safecloud` | `/etc/logrotate.d/safecloud` | Rotation for the stack's own logs (sentinel cron, PHP-FPM slow log, install log) |

### Alerts, dashboard & log rotation

```bash
# Prometheus alert rules (validate, then reference from your prometheus.yml rule_files)
promtool check rules monitoring/prometheus-alerts.yml

# Grafana: Dashboards → Import → upload monitoring/grafana-dashboard.json, pick your Prometheus source.

# Log rotation for the SafeCloud-specific logs (distro packages rotate their own):
sudo cp monitoring/logrotate-safecloud /etc/logrotate.d/safecloud
sudo logrotate -d /etc/logrotate.d/safecloud   # dry-run to verify
```

The alert rules and dashboard scrape the node exporter this stack binds to
`127.0.0.1:9100`, so reach it from your Prometheus/Grafana over an SSH tunnel
(`ssh -L 9100:127.0.0.1:9100 user@host`) or a private scrape path.

## Hardened node exporter unit

The stock node-exporter unit runs with default privileges. This replacement unit applies a strict systemd sandbox:

* **Zero privileges:** `NoNewPrivileges=true`, empty `CapabilityBoundingSet` — metrics gathering needs no root capabilities.
* **Filesystem isolation:** `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `PrivateDevices=true` — the whole OS is read-only to the process, homes and raw devices are invisible.
* **Kernel shielding:** cgroups, kernel tunables, module loading, and the kernel log ring are all protected; syscalls are filtered to the `@system-service` set with debug/mount/module classes removed; only `AF_INET/AF_INET6/AF_UNIX` socket families are allowed.
* **Loopback-only metrics:** `--web.listen-address=127.0.0.1:9100` — telemetry is invisible to the public network and adjacent VPC subnets. Pull metrics over an SSH tunnel: `ssh -L 9100:127.0.0.1:9100 user@host`.
* **Resource ceilings:** `CPUQuota=10%`, `MemoryMax=100M`, `TasksMax=10` — a misbehaving exporter can never starve PHP workers or the database, protecting the stack's engineered memory headroom.

```bash
sudo cp monitoring/prometheus-node-exporter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus-node-exporter.service
systemctl status prometheus-node-exporter.service
```

> Note: `setup.sh` configures the distro package's exporter for loopback binding via `/etc/default/prometheus-node-exporter`. Installing this unit file is the stricter alternative — it overrides the package unit entirely and hardcodes the loopback flag.

## Security Sentinel cron

`safecloud-sentinel.cron` runs [`scripts/alert-apparmor-status.sh`](../scripts/alert-apparmor-status.sh) hourly: it sweeps new kernel audit lines for AppArmor denials, checks core service health via `status-report.sh --json`, and dispatches Discord/Slack alerts only when something is actually wrong.

```bash
# Install the alerting script where the cron expects it
sudo cp scripts/alert-apparmor-status.sh /usr/local/bin/alert-apparmor-status.sh
sudo cp scripts/status-report.sh /usr/local/bin/status-report.sh
sudo chmod 755 /usr/local/bin/alert-apparmor-status.sh /usr/local/bin/status-report.sh

# Activate the schedule
sudo cp monitoring/safecloud-sentinel.cron /etc/cron.d/safecloud-sentinel
```

Set `ALERT_WEBHOOK_URL` (see [`.env.example`](../.env.example)) to receive the webhook alerts; without it, sweeps log to `/var/log/safecloud_sentinel_cron.log` only.

---

*Part of the [SafeCloud.PRO Hardened LEMP Stack](../README.md) · [safecloud.pro](https://safecloud.pro)*
