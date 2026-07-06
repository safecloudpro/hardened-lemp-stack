![SafeCloud.PRO](assets/wm-white.png)

# setup.sh: Hardened LEMP Stack Provisioning Script
### Version 3.3.1 (SafeCloud.PRO LTS Hardened)

`setup.sh` is an advanced, production-grade shell script designed to deploy, secure, and optimize a complete LEMP (Linux, Nginx, MariaDB, PHP) stack on a fresh AWS Graviton/ARM64 t4g.xlarge instance running Ubuntu 26.04 LTS. 

This unified script supports both a step-by-step **Interactive Mode** with real-time explanations and an automated **Headless Mode** for CI/CD pipelines, complete with strict system-budget calculations to completely neutralize Out-Of-Memory (OOM) kernel crashes.

---

## Key Security & Optimization Features

1. **Edge-Layer Cryptographic Isolation (Cloudflare AOP):** Downloads official Cloudflare CA certificates and enforces Authenticated Origin Pulls (`ssl_verify_client on`), ensuring Nginx drops all direct IP scans or origin bypass attempts at the TLS handshake layer.
2. **Mandatory Access Control (Nginx AppArmor Confinement):** Deploys a tailored AppArmor profile (`/etc/apparmor.d/usr.sbin.nginx`) to restrict the Nginx runtime process from executing arbitrary binaries, isolates directories to read-only access, limits local Unix sockets, and protects origin TLS certificates.
3. **Adaptive OOM-Resilient Allocations:** Evaluates host memory and derives *every* memory-sensitive setting (system reserve, Redis cap, InnoDB pool, PHP-FPM worker count) from the RAM the host actually has, so the same script is safe on a 1 GB box and a 16 GB box. On a 16 GB host this lands near a 1.5 GB InnoDB pool, a 1 GB Redis cap, and ~189 static PHP-FPM workers with ample PHP headroom. Pin any value with `--db-pool` / `--php-workers`; both are also clamped so a pinned value can't starve the other tiers into an OOM.
4. **Advanced Bytecode Protection:** Enforces `opcache.validate_permission=1` and `opcache.validate_root=1` to prevent shared-memory cross-site information leaks, and enables CLI-caching (`opcache.enable_cli=1`) for fast background WP-CLI operations. On Ubuntu 26.04, OPcache is **compiled into the PHP 8.5 binary** (there is no `php8.5-opcache` package); the script detects this, skips the missing package without a scary warning, and symlinks the hardened `opcache.ini` into the FPM and CLI `conf.d` directories so the settings actually load.
5. **Socket-Only Redis Object Cache:** Deploys Redis with its TCP listener fully disabled (`port 0`), communicating exclusively over a Unix domain socket with disk persistence off and an auto-sized LRU-evicted memory ceiling (~1 GB on a 16 GB host) — a pure, unexfiltratable in-memory cache.
6. **Local Database Confinement:** Restricts MariaDB 11.x strictly to localhost loopback binding (`127.0.0.1`) with `skip-name-resolve`, removing remote network exploits.
7. **Isolated Telemetry Exporters:** Restricts the Prometheus node exporter to bind strictly to loopback (`127.0.0.1:9100`).

---

## Usage Guide & Command Line Flags

The script must be run with root privileges:

```bash
sudo ./setup.sh [OPTIONS]
```

### Available Options

| Option | Flag | Description |
| :--- | :--- | :--- |
| `--interactive` | `-i` | Runs step-by-step, prompting before each component and logging your choices (Default). |
| `--yes` | `-y` | Headless, non-interactive mode. Installs all components automatically. |
| `--dry-run` | `-d` | Runs system memory allocation checks and prints the configuration budget without modifying files. |
| `--db-pool SIZE` | *None* | Override the MariaDB buffer pool size (e.g., `--db-pool 2G`, `--db-pool 512M`). Default: **auto-sized from RAM** (25 % of RAM, capped at 1.5 GB in auto mode). |
| `--php-workers NUM`| *None* | Override the static PHP-FPM worker count (e.g., `--php-workers 150`). Default: **auto-sized from RAM** (remaining budget ÷ ~50 MB per worker; ≈189 on a 16 GB host). |
| `--php-version VER`| *None* | Force a specific PHP pool version (e.g., `--php-version 8.5`). Default: **auto-detected from the release's APT repositories** (Ubuntu 26.04 → 8.5), with a pre-flight check that aborts the component cleanly if the requested series doesn't exist. |
| `--exclude-exporters`| *None*| Skips the installation of the local Prometheus Node Exporter. |
| `--full-upgrade` | *None* | Headless: upgrade all system packages to the latest available versions before installing (interactive mode always asks). Idempotent. |
| `--wp-cli` | *None* | Headless: install WP-CLI to `/usr/local/bin/wp` (interactive mode always asks). Idempotent — skips if already present. |
| `--no-tune` | *None* | Skip the post-install fine-tuning advisor ([`tune-stack.sh`](../tune-stack.sh)). |
| `--configure-sg` | *None* | Headless: also generate the Cloudflare→EC2 Security Group commands ([`configure-security-group.sh`](../configure-security-group.sh)); interactive mode always offers it. |
| `--no-color` | *None* | Disables colored terminal logs. |
| `--help` | `-h` | Opens the script helper documentation. |

---

## Step-by-Step Installation Component Roadmap

When running in **Interactive Mode**, the script will present each phase individually:

### 0. Pre-flight options (asked first)
Before any component installs, the script offers two optional steps (interactive
mode asks; headless enables them with `--full-upgrade` / `--wp-cli`):
* **Full system upgrade** — `apt-get update && apt-get full-upgrade` to bring every
  package to its latest available version, then `autoremove`. Idempotent; flags a
  reboot if the kernel changed.
* **WP-CLI** — installs the WordPress command-line tool to `/usr/local/bin/wp`
  (idempotent — skips if already present). Usable once PHP is installed below.

After the components finish, the script also offers **post-install fine-tuning**
([`../tune-stack.sh`](../tune-stack.sh)) and the **Cloudflare Security Group command
generator** ([`../configure-security-group.sh`](../configure-security-group.sh)) —
see the main README's deployment playbook.

### 1. System Updates & UFW Firewall
* Installs fail2ban, unattended-upgrades, curl, and openssl.
* Restricts UFW firewall inbound traffic, opening only **SSH (22)**, **HTTP (80)**, **HTTPS (443/TCP)**, and **HTTP/3 QUIC (443/UDP)**.

### 2. Nginx HTTP/3 Server Configuration
* Installs Nginx together with `ssl-cert` (generates the snakeoil placeholder certificate the server block boots with until your Cloudflare Origin Certificate is installed).
* Configures global Nginx blocks, hiding server signatures (`server_tokens off;`) and adding MIME-type security headers.
* Configures the WordPress block, mapping the local fastcgi PHP socket and explicitly **denying PHP execution in public upload folders** (`/wp-content/uploads/.*\.php$`).
* On a config failure the script prints the full `nginx -t` output instead of a bare error code.

### 3. Nginx AppArmor Profile Containment
* Writes, loads, and enforces a mandatory AppArmor profile restricting `/usr/sbin/nginx`.
* Enforces read-only permissions across site webroots, strictly denies write privileges to active plugin and theme directories, blocks command line execution, and limits local socket bounds.

### 4. PHP-FPM & OPcache Hardening
* Installs `phpX.Y-fpm` first (on its own, so one missing optional extension can't abort the whole transaction), then the optional extensions (`mysql`, `opcache`, `curl`, `xml`, `mbstring`) individually. Extensions that are compiled into the PHP binary rather than shipped as a package (e.g. OPcache on Ubuntu 26.04) are detected and skipped without a false warning.
* Creates the optimized PHP pool, disabling dangerous built-in operations (`disable_functions = exec,system,shell_exec,passthru,popen,proc_open,show_source`). The `sed` that sets this matches both the commented (`;disable_functions =`) and the active-but-empty (`disable_functions = `) spellings PHP's stock `php.ini` ships.
* Enforces `security.limit_extensions = .php` and `cgi.fix_pathinfo = 0` to close disguised-extension and PATH_INFO script-guessing vectors.
* Configures a static, recycled process manager (`pm = static`, `pm.max_requests = 1000`) and wires the hardened `opcache.ini` (with `validate_permission`/`validate_root`) into the FPM and CLI SAPIs.

### 5. Redis Object Cache (Unix-Socket Only)
* Installs `redis-server` first (on its own), then the matching `phpX.Y-redis` extension; if that extension package is unavailable it warns and continues (Redis itself is still configured).
* Disables the TCP listener entirely (`port 0`) — Redis is reachable only via `/var/run/redis/redis-server.sock` (mode `770`).
* Runs as a pure cache: persistence off (`save ""`, `appendonly no`), an **auto-sized** `maxmemory` ceiling (RAM-derived, ~1 GB on a 16 GB host), `allkeys-lru` eviction, lazy-free enabled.
* Adds `www-data` to the `redis` group so PHP-FPM workers can reach the socket.

### 6. MariaDB 11.x Local Loopback
* Writes hardening as a **drop-in override** (`/etc/mysql/mariadb.conf.d/60-safecloud-hardening.cnf`) rather than replacing the distro's `50-server.cnf` — packaging paths stay authoritative, so MariaDB point releases can't break startup.
* Binds the database strictly to localhost (`bind-address = 127.0.0.1`, `skip-name-resolve`) and applies the customized memory buffers.
* On a failed start, prints the last 15 lines of `journalctl -u mariadb` for immediate diagnosis.

### 7. Isolated Prometheus Telemetry
* Installs `prometheus-node-exporter` and forces its metrics endpoint to bind to loopback.

---

## Log Output
At the conclusion of the installation process, the script compiles a summary log of all accepted, skipped, and completed components, displaying it to the terminal and saving it permanently to `./installation_choices.log` and `/var/log/lemp_interactive_install.log`.
