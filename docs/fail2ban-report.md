![SafeCloud.PRO](assets/wm-white.png)

# fail2ban-report.sh: Automated Security Intrusion Log Reporter
### Version 1.0.0 (SafeCloud.PRO Security Sentinel)

`fail2ban-report.sh` is an advanced, automated security log parsing utility designed specifically for the hardened WordPress + WooCommerce LEMP stack on **Ubuntu 26.04 LTS**. It parses local system logs in real-time, extracts malicious IP intrusion attempts, groups them by jail, highlights the top offending IP addresses, and posts a visual audit digest directly to your designated **Slack or Discord security channel**.

---

## Technical Features & Intrusion Aggregation

The reporter operates directly on the system's firewall daemon boundary, delivering robust operational visibility:
1. **Interactive and Non-Interactive Parsing**: Evaluates `/var/log/fail2ban.log` to aggregate system bans and unbans.
2. **Jail-Specific Micro-Metrics**: Dynamically extracts block counts and top offending attackers for each security slice, including `sshd`, Nginx-AppArmor blocks, and Nginx WordPress login endpoints.
3. **Multi-Platform Webhook Integrations**: 
   * **Discord**: Builds a rich, color-coded embed card featuring security emojis, host summaries, and dynamic list arrays.
   * **Slack**: Generates clean, markdown-formatted block blocks optimized for rapid reading on mobile devices.
4. **Structured JSON Mode**: Supports a `--json` parameter to output the security metrics as a pure JSON object, perfect for forwarding to centralized SIEM platforms or custom endpoints.

---

## Command Line Usage & Reference

The script must be run with root privileges to read system log boundaries:

```bash
sudo ./scripts/fail2ban-report.sh [OPTIONS]
```

### Available Options

| Option | Flag | Description |
| :--- | :--- | :--- |
| `--file PATH` | `-f` | Path to the Fail2ban log file to parse (Default: `/var/log/fail2ban.log`). |
| `--output FILE`| `-o` | Writes a plain, uncolored version of the text report directly to a file. |
| `--json` | `-j` | Outputs the parsed metrics as a structured JSON object. |
| `--webhook URL`| `-w` | Manually overrides the target Discord or Slack Webhook URL. |
| `--dry-run` | `-d` | Executes parsing and prints the console summary without sending the webhook. |
| `--no-color` | *None*| Disables colored text terminal outputs. |
| `--help` | `-h` | Shows this help menu and exits. |

---

## Staging & Production Deployment

To automate this log monitoring utility to run daily and notify your security team:

### Step 1: Install the Reporter
Copy the reporter to your system's local binary directory and give it execute permissions:
```bash
sudo cp fail2ban-report.sh /usr/local/bin/fail2ban-report.sh
sudo chmod +x /usr/local/bin/fail2ban-report.sh
```

### Step 2: Configure the Webhook Variable
Ensure your Slack or Discord Webhook URL is defined in your website's environment variables (`/var/www/html/.env`):
```env
ALERT_WEBHOOK_URL="https://discord.com/api/webhooks/YOUR_WEBHOOK_DETAILS"
```

### Step 3: Schedule the Daily Cron Job
Create a persistent Cron file at `/etc/cron.d/fail2ban-reporter` to execute the audit every night at midnight:
```text
# Run the Fail2ban Security Report daily at 00:00 as root
0 0 * * * root /usr/local/bin/fail2ban-report.sh >/dev/null 2>&1
```

Set correct permissions on the cron file:
```bash
sudo chmod 0644 /etc/cron.d/fail2ban-reporter
```

---

## Troubleshooting & Verification

You can test the entire pipeline non-destructively by initiating a dry-run or force-sending a diagnostic card directly from your terminal:

```bash
# Verify log parsing works on your system (Console output only)
sudo /usr/local/bin/fail2ban-report.sh -d

# Force compile and send a live webhook notification to your security channel
sudo /usr/local/bin/fail2ban-report.sh
```

Blocked connection attempts and AppArmor sandbox triggers will be automatically aggregated and reported.

---
*Document managed and maintained by SafeCloud.PRO Operations • July 2026*
