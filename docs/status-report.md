![SafeCloud.PRO](assets/wm-white.png)

# status-report.sh: LEMP Stack Security Auditing & Health Check Tool
### Version 2.2.0 (SafeCloud.PRO Monitoring Suite)

`status-report.sh` is an on-demand security scanner and system-state auditor. It performs detailed configuration and runtime process validations across your entire stack to check for configuration drift, verify file safety, and evaluate service statuses.

It supports structured **JSON output** for integrations with central monitoring hooks (e.g., Cron triggers, system health daemons, or custom Webhook alerts).

---

## Auditing and Inspection Parameters

The script verifies 6 primary layers of your secure architecture:

### 1. Firewall Integrity
* Reads the active status of `ufw` and logs all currently open external port bindings.

### 2. Web Server Configuration & MAC Containment
* Validates Nginx runtime states.
* Confirms the presence of the **Cloudflare Authenticated Origin Pull (AOP)** cryptographic certificate at `/etc/nginx/certs/cloudflare.crt`, ensuring direct IP origin bypasses remain blocked.
* Audits the **Nginx AppArmor containment profile** to ensure Nginx is running in full confinement (`ACTIVE (Enforced)`) under AppArmor, restricting filesystem write boundaries and blocking command/shell execution.

### 3. PHP-FPM & OPcache Security
* Detects the active running PHP FPM pool.
* Verifies whether critical security constants (like `opcache.validate_permission = 1` and `disable_functions`) are properly loaded in the FPM mod-structures to prevent privilege escalation or directory traversal leaks.

### 4. Database Confinement
* Confirms MariaDB's listener is bound strictly to `127.0.0.1` on local port 3306.
* Reads the running InnoDB buffer pool memory cache allocations to verify growth margins.

### 5. Observability and Monitoring Isolation
* Verifies that the Prometheus `node_exporter` is active.
* Confirms that its scrape bindings are restricted strictly to loopback (`127.0.0.1:9100`), preventing metrics from being exposed over public networks or VPC subnets.

---

## Usage Guide & Command Line Flags

```bash
./scripts/status-report.sh [OPTIONS]
```

### Available Options

| Option | Flag | Description |
| :--- | :--- | :--- |
| `--output FILE` | `-o` | Saves the uncolored plain text audit report directly to a file without prompting. |
| `--quiet` | `-q` | Quiet mode. Suppresses console output. Exits with code `0` if all services are active and secure, and `1` if any critical checks fail (perfect for cron job automation). |
| `--json` | `-j` | Outputs findings as a clean, structured JSON object, ideal for integrating with external monitoring hooks. |
| `--no-color` | *None* | Disables colored terminal logs. |
| `--help` | `-h` | Opens the script helper documentation. |

---

## Integration Examples

### 1. Automated Hourly Security Audit (via Cron)
To run a silent hourly check that writes directly to an audit folder:
```bash
0 * * * * /path/to/status-report.sh -o /var/log/audit/lemp_hourly_report.txt
```

### 2. Cron Alerting on Failure
To run a silent check that alerts system administrators if Nginx, PHP, or MariaDB is offline:
```bash
*/5 * * * * /path/to/status-report.sh -q || echo "Alert: Secure LEMP stack down on host $(hostname)!" | mail -s "CRITICAL Stack Down" admin@safecloud.pro
```

### 3. Integrating with Custom Monitoring (JSON)
Execute the script to output pure JSON data for parsing:
```bash
./scripts/status-report.sh --json | jq '.system_and_edge.nginx_apparmor_status'
```
