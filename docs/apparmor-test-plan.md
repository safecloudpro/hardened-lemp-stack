![SafeCloud.PRO](assets/wm-white.png)

# SafeCloud.PRO - AppArmor Security Confinement Test Plan
### Operational Playbook for Confinement Verification on Ubuntu 26.04 LTS
**Document Version**: 1.0.0  
**Target Environment**: Hardened WooCommerce LEMP Stack  
**Objective**: Safe, non-destructive verification that Nginx, PHP-FPM, MariaDB, and Redis are running inside their respective kernel-level mandatory access control (MAC) sandboxes and successfully blocking unauthorized behaviors.

---

## ⚠️ Pre-Test Warnings & Rules
1. **Never run these tests in a production environment.** These tests intentionally simulate exploit behavior and file modifications which can cause runtime errors or lockouts. Run them ONLY in an isolated staging or local virtualized environment.
2. **Review your Logging Pipeline:** AppArmor denials are intercepted at the kernel level and logged. Before starting, identify your logging destination:
   * System Audit Daemon: `/var/log/audit/audit.log`
   * Kernel Log: `/var/log/syslog` or `dmesg`
   * Systemd Journal: `journalctl -fx` (highly recommended for live tracking)

---

## 🛠 Pre-Test Setup: Audit Live Monitoring
Open a dedicated terminal window on your staging server and run the following command to watch AppArmor denials in real-time as you execute this test plan:

```bash
# Monitor live kernel audit events specifically for AppArmor violations
sudo journalctl -g "apparmor" -f
# Or monitor raw audit log streams if auditd is installed
sudo tail -f /var/log/audit/audit.log | grep "ALLOWED" || sudo tail -f /var/log/syslog | grep "DENIED"
```

---

## 🧪 Test Suite 1: Nginx Confinement (`usr.sbin.nginx`)
Your Nginx AppArmor profile restricts the web server process from executing system shells, binding on unapproved ports, and writing to the application codebase directory.

### Test 1.1: System Command Execution (Anti-RCE)
* **Goal**: Verify that Nginx cannot execute host binaries even if a vulnerability is present.
* **Execution**: Nginx should not be able to execute any command in `/bin/` or `/usr/bin/`. We will test this by attempting to map an execution block or trigger a fastcgi command execution.
* **Verification Command**:
  Verify your Nginx configuration blocks execution by checking if Nginx can execute any basic shell paths. If you attempt to use an Nginx directive to run a command or spawn a sub-shell, it must return a kernel audit denial.
* **Expected AppArmor Log Entry**:
  Look for a log entry containing: `profile="/usr/sbin/nginx"`, `operation="exec"`, `denied_mask="x"`, and `requested_mask="x"`.

### Test 1.2: Codebase Directory Write Containment
* **Goal**: Verify Nginx cannot write, append, or modify `.php` files inside `/wp-admin` or `/wp-includes` (protecting against persistent file skimmers).
* **Execution**: Run a command as the web user (`www-data`) simulating Nginx trying to write to a forbidden path:
  ```bash
  sudo -u www-data touch /var/www/html/wp-admin/malicious_skimmer.php
  ```
* **Expected Result**: System returns `Permission denied`.
* **Expected AppArmor Log Entry**:
  Look for a log entry containing: `profile="/usr/sbin/nginx"`, `operation="open"`, `denied_mask="wc"`, and `name="/var/www/html/wp-admin/malicious_skimmer.php"`.

---

## 🧪 Test Suite 2: PHP-FPM Confinement (`usr.sbin.php-fpm`)
PHP-FPM executes your dynamic site code, making it the primary target for attackers. This profile denies execution of system commands (like `whoami`, `curl`, `wget`) and restricts writes strictly to asset uploads.

### Test 2.1: PHP Shell Execution Block (Command Execution)
* **Goal**: Verify that PHP-FPM cannot execute command-line utilities.
* **Execution**: Create a temporary test file named `/var/www/html/test-rce-block.php` containing:
  ```php
  <?php
  echo "Attempting to execute shell command 'id':<br>";
  $output = shell_exec('id');
  echo "Output: " . ($output ? $output : "BLOCKED (No output or null returned)");
  ?>
  ```
  Access this file via your browser: `https://your-staging-site.com/test-rce-block.php`.
* **Expected Result**: The browser output must show `BLOCKED` (or a blank screen/error), and the server command line must log a kernel audit breach.
* **Expected AppArmor Log Entry**:
  Look for a log containing: `profile="/usr/sbin/php-fpm"`, `operation="exec"`, `denied_mask="x"`, and `name="/usr/bin/id"` (or `/bin/dash`/`/bin/sh`).

### Test 2.2: Exploit Sandbox Directory Protection (Upload Directory Execution)
* **Goal**: Verify that even if an attacker successfully uploads a `.php` file to `/wp-content/uploads/`, the system blocks execution.
* **Execution**:
  1. Create a dummy PHP script inside uploads:
     ```bash
     sudo -u www-data echo "<?php phpinfo(); ?>" > /var/www/html/wp-content/uploads/exploit.php
     ```
  2. Attempt to request this file in your browser: `https://your-staging-site.com/wp-content/uploads/exploit.php`.
* **Expected Result**: Nginx must return a `403 Forbidden` response.
* **Clean-up**: Remove the test exploit file:
  ```bash
  sudo rm /var/www/html/wp-content/uploads/exploit.php
  ```

---

## 🧪 Test Suite 3: MariaDB Confinement (`usr.sbin.mariadbd`)
MariaDB houses your customer and financial records. This profile prevents database-driven filesystem access (like SQL-injection reading private keys or writing web shells).

### Test 3.1: SQL Injection File-Write Block (`SELECT INTO OUTFILE`)
* **Goal**: Verify that MariaDB cannot write database table contents to arbitrary system folders.
* **Execution**: Log into your local MariaDB shell as the database administrator and attempt to dump records directly to Nginx's web root:
  ```sql
  -- Attempt to write files outside of MariaDB's data storage partition
  SELECT * FROM mysql.user INTO OUTFILE '/var/www/html/wp-content/uploads/database_dump.txt';
  ```
* **Expected Result**: Query fails with `ERROR 1 (HY000): Can't create/write to file` or a system permissions error.
* **Expected AppArmor Log Entry**:
  Look for a log entry containing: `profile="/usr/sbin/mariadbd"`, `operation="open"`, `denied_mask="wc"`, and `name="/var/www/html/wp-content/uploads/database_dump.txt"`.

---

## 🧪 Test Suite 4: Redis Confinement (`usr.sbin.redis-server`)
Your Redis configuration completely disables standard TCP ports and communicates exclusively via UNIX domain sockets. This profile enforces that isolation directly at the kernel layer, blocking network traffic.

### Test 4.1: Network Port Binding Block (Anti-Exfiltration)
* **Goal**: Verify that the Redis process is barred from opening network ports or starting network listeners.
* **Execution**:
  1. Edit your staging `/etc/redis/redis.conf` temporarily to re-enable TCP networking (change `port 0` to `port 6379`).
  2. Attempt to restart the Redis service:
     ```bash
     sudo systemctl restart redis-server
     ```
* **Expected Result**: The service fails to restart or throws startup binding errors in the system logs.
* **Expected AppArmor Log Entry**:
  Look for a log entry containing: `profile="/usr/sbin/redis-server"`, `operation="create"`, `denied_mask="raw"`, and `family="inet"`.
* **Important**: Revert `/etc/redis/redis.conf` to `port 0` immediately after testing and restart Redis.

---

## 📊 Post-Verification Compliance Logging
Once you have run all tests, you can output your compliance verification summary to present to auditors. Use this command to compile a clean, readable text report:

```bash
# Compile and count blocked security events for your monthly audit report
echo "=========================================================="
echo "    AppArmor Mandatory Access Control Verification Audit  "
echo "    Date: $(date)"
echo "=========================================================="
echo " Confinement Violation Block Counts:"
echo "----------------------------------------------------------"
echo "  - Nginx Denials:      $(sudo dmesg | grep -c "profile=\"/usr/sbin/nginx\"")"
echo "  - PHP-FPM Denials:    $(sudo dmesg | grep -c "profile=\"/usr/sbin/php-fpm\"")"
echo "  - MariaDB Denials:    $(sudo dmesg | grep -c "profile=\"/usr/sbin/mariadbd\"")"
echo "  - Redis Denials:      $(sudo dmesg | grep -c "profile=\"/usr/sbin/redis-server\"")"
echo "=========================================================="
```
