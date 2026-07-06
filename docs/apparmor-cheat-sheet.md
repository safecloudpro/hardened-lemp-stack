![SafeCloud.PRO](assets/wm-white.png)

# SafeCloud.PRO - AppArmor Deployment & Administration Cheat Sheet
### Production-Grade Mandatory Access Control (MAC) Management for Ubuntu 26.04 LTS

AppArmor provides a crucial security layer on Ubuntu 26.04 LTS by confining critical system daemons to a strict, least-privilege mandatory access control boundary. Even if a vulnerability (such as a remote code execution exploit) is compromised in the application layer, AppArmor intercepts kernel-level requests to block unauthorized process spawns, file writes, and network connections.

This cheat sheet serves as a definitive administrative reference guide for deploying, auditing, troubleshooting, and maintaining the AppArmor profiles for your Nginx, PHP-FPM, MariaDB, and Redis layers.

---

## 🏗 SafeCloud.PRO Profile Registry

| Confined Daemon | AppArmor Profile Path | Target Executable | Target Services |
| :--- | :--- | :--- | :--- |
| **Nginx Web Tier** | `/etc/apparmor.d/usr.sbin.nginx` | `/usr/sbin/nginx` | `nginx.service` |
| **PHP-FPM Pool** | `/etc/apparmor.d/usr.sbin.php-fpm` | `/usr/sbin/php-fpm*` | `php8.5-fpm.service` (Ubuntu 26.04; match your PHP series) |
| **MariaDB Database** | `/etc/apparmor.d/usr.sbin.mariadbd` | `/usr/sbin/mariadbd` | `mariadb.service` (disable the distro `mariadbd` profile first — see apparmor/README.md) |
| **Redis Cache** | `/etc/apparmor.d/usr.sbin.redis-server` | `/usr/sbin/redis-server` | `redis-server.service` (attach via systemd drop-in — NoNewPrivileges) |

---

## 🚀 1. Quick-Start Deployment Workflow

When deploying a new profile or applying updates to an existing one, follow this exact sequence to ensure syntax validity and prevent service disruptions:

```bash
# Step 1: Install required AppArmor administrative utility tools
sudo apt-get update && sudo apt-get install -y apparmor-utils apparmor-profiles

# Step 2: Copy your profile file into the system security directory
sudo cp apparmor/usr.sbin.nginx /etc/apparmor.d/usr.sbin.nginx

# Step 3: Validate the syntax of the profile without loading it
sudo apparmor_parser -vn /etc/apparmor.d/usr.sbin.nginx

# Step 4: Parse, compile, and enforce the profile at the kernel level
# -r: Replace existing profile
# -W: Write binary cache to speed up subsequent system boots
sudo apparmor_parser -r -W /etc/apparmor.d/usr.sbin.nginx

# Step 5: Reload the target service to bind it to the newly loaded profile
sudo systemctl restart nginx
```

---

## 📊 2. Active Confinement Auditing

Always verify that your profiles are actively attached to running processes. A profile loaded into the kernel does not protect the server unless the running process is confined.

```bash
# Check the overall status of AppArmor profiles in the kernel
sudo aa-status

# Quick check: List all network-facing processes that are NOT confined
sudo aa-unconfined

# Verify the confinement state of a specific target daemon
sudo aa-status | grep -E "nginx|php-fpm|mariadb|redis"

# Inspect the active processes to see if they are in "enforced" or "complain" mode
# Expected output format: /usr/sbin/nginx (12345) user.sbin.nginx
ps -auxZ | grep -E "nginx|php|mariadb|redis"
```

---

## 🛠 3. Debugging & Maintenance Toggles

If you suspect an AppArmor profile is blocking legitimate application traffic (e.g., a newly installed WordPress plugin attempting to write to a custom cache directory), use these commands to safely isolate and resolve the issue:

### Complain Mode (Permissive Logging)
Complain mode allows the process to perform all actions, but logs any violations that would have been blocked under Enforce mode. This is ideal for testing custom plugins in staging.
```bash
# Put Nginx into complain mode (stops blocking, starts logging)
sudo aa-complain /etc/apparmor.d/usr.sbin.nginx

# Re-read and compile the profile in complain mode
sudo apparmor_parser -r -W /etc/apparmor.d/usr.sbin.nginx

# Gracefully reload the service to apply the permissive mode
sudo systemctl reload nginx
```

### Enforce Mode (Hard Lockdown)
Once validation completes, always return profiles to Enforce mode to guarantee mandatory access control.
```bash
# Return Nginx to full enforcement mode
sudo aa-enforce /etc/apparmor.d/usr.sbin.nginx

# Re-read and compile the profile in enforce mode
sudo apparmor_parser -r -W /etc/apparmor.d/usr.sbin.nginx

# Gracefully reload the service to apply the lockdown
sudo systemctl reload nginx
```

### Disabling a Profile Temporarily
If you need to completely remove a profile's confinement for maintenance:
```bash
# Create a symlink in the AppArmor disable directory
sudo ln -s /etc/apparmor.d/usr.sbin.nginx /etc/apparmor.d/disable/

# Remove the profile from the running kernel
sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.nginx

# To re-enable later:
sudo rm /etc/apparmor.d/disable/usr.sbin.nginx
sudo apparmor_parser -r -W /etc/apparmor.d/usr.sbin.nginx
```

---

## 🔍 4. Log Inspection & Hex Decoding

AppArmor violations are logged directly to the system audit daemon (`auditd`) or the kernel log buffer.

```bash
# Read live AppArmor denials as they occur
sudo tail -f /var/log/audit/audit.log | grep "apparmor"
# Or via syslog if auditd is not installed:
sudo tail -f /var/log/syslog | grep "apparmor"

# Use journalctl to view denials across systemd boots
sudo journalctl -fx -t apparmor
```

### Translating Hex-Encoded Paths
When AppArmor denies a path containing special characters, it logs the target path as a hex-encoded string (e.g., `\x2f7661722f777777...`). You must decode this string to identify the blocked resource.

```bash
# Decode a hex-encoded AppArmor denial path instantly
# Example target input: 2f7661722f7777772f68746d6c
echo "2f7661722f7777772f68746d6c" | xxd -r -p

# Standard AppArmor tool to decode and format active logs
sudo aa-decode
```

### Typical Denial Log Schema Breakdown
```text
type=AVC msg=audit(1719943200.123:456): apparmor="DENIED" operation="open" profile="usr.sbin.nginx" name="/var/www/html/wp-config.php" pid=12345 comm="nginx" requested_mask="w" denied_mask="w" fsuid=33 ouid=33
```
*   `profile="usr.sbin.nginx"`: The AppArmor policy that caught the infraction.
*   `operation="open"`: The system call that was blocked.
*   `name="/var/www/html/wp-config.php"`: The exact file Nginx attempted to modify.
*   `requested_mask="w"`: The program requested Write (`w`) access.
*   `denied_mask="w"`: Write access was denied by AppArmor to protect code integrity.

---

## 🛡 5. AppArmor 5.x Advanced Policy Management

Ubuntu 26.04 LTS includes **AppArmor 5.x**, which introduces advanced mediation features:

### 1. Pinning User Namespaces (`userns` containment)
To prevent unprivileged user namespace exploits, you can append `userns` blocks to your profiles.
*   Add this inside `/etc/apparmor.d/usr.sbin.php-fpm` to block PHP from spawning rootless child namespaces:
    ```text
    deny userns,
    ```

### 2. Mediating the `io_uring` Interface
`io_uring` is a high-performance kernel asynchronous interface but presents a broad attack surface. AppArmor 5.x allows granular control:
*   To categorically block `io_uring` allocations for the Nginx process, append this rule to the profile:
    ```text
    deny io_uring,
    ```

---

*This Operational Cheat Sheet is designed for the SafeCloud.PRO DevOps and Infrastructure teams. Keep it open in a secondary terminal session for fast administrative response.*
