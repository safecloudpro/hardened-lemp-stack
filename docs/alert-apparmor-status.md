![SafeCloud.PRO](assets/wm-white.png)

# alert-apparmor-status.sh: Security Sentinel & AppArmor Alerting Engine
### Version 1.0.0 (SafeCloud.PRO Monitoring Suite)

`alert-apparmor-status.sh` is an automated health-check and security auditing tool designed for **Ubuntu 26.04 LTS**. It queries your system using `status-report.sh` and sweeps active kernel log files (e.g., `/var/log/audit/audit.log`) for unauthorized AppArmor access control violations.

If an incident occurs—such as a critical stack service falling offline or a plugin attempting an unauthorized action blocked by AppArmor—the script compiles a structured JSON payload and immediately dispatches a styled alert card to your designated **Slack or Discord webhook channel**.

---

## Technical Mechanisms

1. **Incremental Log Cursor:** The script maintains a persistent log pointer (`/var/lib/safecloud/apparmor_last_line.txt`). Instead of parsing full logs on every run, it only sweeps the newly appended log lines for keywords like `apparmor="DENIED"` or `denied_mask`. This eliminates CPU overhead and prevents duplicate alert storms.
2. **Automated Incident Isolation:** The script only triggers webhook posts when an active breach or service down-state is discovered, keeping your alerting channel clean and free from routing noise.
3. **Styled Webhook Embeds:** Generates rich Discord/Slack embeds featuring color-coded statuses (Green for normal, Orange for blocked security violations, Red for service outages) and details the specific denied executable, path, and target file.

---

## Deployment & Cron Activation

To activate hourly automated auditing, move the files to their secure system paths on your staging/production EC2 host:

```bash
# 1. Move the alert runner to the secure system binaries path
sudo cp alert-apparmor-status.sh /usr/local/bin/alert-apparmor-status.sh
sudo chmod +x /usr/local/bin/alert-apparmor-status.sh

# 2. Add your Slack/Discord webhook URL to your environment file
# Edit /var/www/html/.env (or equivalent webroot paths) and append:
# ALERT_WEBHOOK_URL="https://discord.com/api/webhooks/..."

# 3. Register the cron schedule job
sudo cp lemp-status-alert.cron /etc/cron.d/lemp-status-alert
sudo chmod 0644 /etc/cron.d/lemp-status-alert
```

---

## Direct CLI Usage & Overrides

You can run the script manually from your terminal to verify settings or override default parameters:

```bash
# Test manual dispatch by passing an explicit Webhook URL
sudo /usr/local/bin/alert-apparmor-status.sh --webhook "https://discord.com/api/webhooks/..."

# Specify a customized path to status-report.sh
sudo /usr/local/bin/alert-apparmor-status.sh -w "https://slack.com/..." -s "/opt/status-report.sh"
```
