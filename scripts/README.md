![SafeCloud.PRO](../docs/assets/wm-white.png)

# Operations Scripts — Audit, Verify, Benchmark, Alert

Flag-driven tooling for day-2 operation of the hardened stack. Every script supports `--help`, honors `--no-color`, and auto-disables color when piped.

| Script | Purpose | Root? | Docs |
| :--- | :--- | :---: | :--- |
| `status-report.sh` | Full security & configuration audit (text/JSON/quiet exit-code modes) | for full detail | [docs/status-report.md](../docs/status-report.md) |
| `verify-apparmor.sh` | AppArmor enforcement audit + non-destructive containment tests + compliance report | ✔ | [docs/verify-apparmor.md](../docs/verify-apparmor.md) |
| `alert-apparmor-status.sh` | Incremental AppArmor-denial sweeper with Discord/Slack webhook alerts | ✔ | [docs/alert-apparmor-status.md](../docs/alert-apparmor-status.md) |
| `fail2ban-report.sh` | Ban statistics per jail: terminal report, JSON, or webhook digest | ✔ | [docs/fail2ban-report.md](../docs/fail2ban-report.md) |
| `performance-benchmark.sh` | Redis socket-vs-TCP latency, HTTP concurrency (ApacheBench), FPM/DB sizing audit | — | [docs/performance-benchmark.md](../docs/performance-benchmark.md) |

### Related top-level tools (repo root, not in `scripts/`)

| Script | Purpose |
| :--- | :--- |
| [`../tune-stack.sh`](../tune-stack.sh) | Re-tune the installed stack to the host's RAM/CPU — detect → confirm → current-vs-proposed diff → apply (with per-service backup + rollback). Re-run after any instance resize. |
| [`../configure-security-group.sh`](../configure-security-group.sh) | Pull Cloudflare's current IP ranges and **generate** the AWS CLI commands (with this instance's real IDs baked in) that build/attach an EC2 Security Group via managed prefix lists, restricting inbound 80/443 to Cloudflare. Writes a reviewable script; you run it under your own AWS credentials. |

## Quick start

```bash
chmod +x scripts/*.sh

# Audit the whole stack and export a compliance report
sudo ./scripts/status-report.sh -o ./system_status_report.txt

# Verify kernel confinement is enforced
sudo ./scripts/verify-apparmor.sh

# Profile performance under load
./scripts/performance-benchmark.sh -c 50 -n 5000
```

For unattended health checks, `status-report.sh --quiet` exits non-zero when a core service is down — ideal for CI probes and external uptime monitors. The alerting pipeline (hourly cron + webhooks) is described in [monitoring/README.md](../monitoring/README.md).

---

*Part of the [SafeCloud.PRO Hardened LEMP Stack](../README.md) · [safecloud.pro](https://safecloud.pro)*
