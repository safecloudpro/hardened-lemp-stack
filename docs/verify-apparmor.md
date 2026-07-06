![SafeCloud.PRO](assets/wm-white.png)

# verify-apparmor.sh: Automated AppArmor Verification & Compliance Auditor
### Version 1.0.0 (SafeCloud.PRO Security Suite)

`verify-apparmor.sh` is an automated test runner designed to run safe, non-destructive validation checks directly on a staging server. It confirms that your kernel-level AppArmor security sandboxes are loaded and successfully blocking malicious operations (such as codebase directory file-writes or unauthorized local socket bindings).

---

## Hardening Tests Executed

The script automates four key compliance verification suites:

### 1. Nginx Write Containment (`usr.sbin.nginx`)
* Simulates the Nginx execution user (`www-data`) attempting to write a file (`malicious_skimmer.php`) into `/wp-admin/` or `/wp-includes/`.
* Verifies that the kernel rejects the write action with an explicit `Permission Denied` code.

### 2. PHP Uploads Execution Block (`usr.sbin.php-fpm`)
* Checks that your active Nginx server configuration actively filters out and blocks any attempts to request or execute raw `.php` payloads uploaded inside the media assets directory `/wp-content/uploads/`.

### 3. Database SQL-Injection Containment (`usr.sbin.mariadbd`)
* Simulates an attacker exploiting a SQL injection vulnerability to dump table structures directly to your public webroot.
* Mimics this behavior by forcing the database system user (`mysql`) to write a mock file (`database_dump.txt`) into `/wp-content/uploads/` and verifies that the operating system blocks the write.

### 4. Redis Memory Socket Isolation (`usr.sbin.redis-server`)
* Verifies that Redis is configured to disable standard TCP networking (via `port 0`).
* Confirms that Redis communicates exclusively over secure local UNIX memory pipes (`/var/run/redis/redis-server.sock`) to completely eliminate lateral network-sniffing vectors.

---

## Usage Guide & Command Line Flags

The script must be run with root privileges (via `sudo`) to query active kernel states and simulate different service users:

```bash
sudo ./scripts/verify-apparmor.sh
```

### Report Export
At the conclusion of the test run, the script parses the system audit log or `dmesg` buffer, summarizes any blocked security events, and writes an auditor-ready compliance sign-off report directly to **`/var/log/safecloud_apparmor_compliance.txt`**.
