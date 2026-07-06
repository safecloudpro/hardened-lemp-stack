# AppArmor Profiles — Kernel-Level Service Confinement

![SafeCloud.PRO](../docs/assets/wm-white.png)

Production AppArmor mandatory access control (MAC) profiles for every daemon in the SafeCloud.PRO hardened LEMP stack, targeting **Ubuntu 26.04 LTS**. Each profile confines its service to a strict least-privilege boundary at the kernel layer: even if an application-layer vulnerability (e.g. an RCE in a WordPress plugin) is exploited, the kernel blocks unauthorized process spawns, file writes, and network connections.

| File | Confines | Deploys to | Shows in `aa-status` as |
| :--- | :--- | :--- | :--- |
| `usr.sbin.nginx` | Nginx web tier | `/etc/apparmor.d/usr.sbin.nginx` | `/usr/sbin/nginx` |
| `usr.sbin.php-fpm` | PHP-FPM pool (8.4/8.5/8.6) | `/etc/apparmor.d/usr.sbin.php-fpm` | `php-fpm` (named profile) |
| `usr.sbin.mariadbd` | MariaDB 11.x database | `/etc/apparmor.d/usr.sbin.mariadbd` | `/usr/sbin/mariadbd` |
| `usr.sbin.redis-server` | Redis object cache | `/etc/apparmor.d/usr.sbin.redis-server` | `/usr/sbin/redis-server//&unconfined` |
| `redis-server-apparmor.conf` | systemd drop-in that *attaches* the Redis profile | `/etc/systemd/system/redis-server.service.d/apparmor.conf` | — |

The four `usr.sbin.*` files are named after their deploy target, so installation is a straight copy — no renaming.

### Two deployment gotchas (both handled by the deploy block below)

1. **MariaDB ships its own profile.** The `mariadb-server` package installs `/etc/apparmor.d/mariadbd`, which attaches the *same* binary path (`/usr/sbin/mariadbd`) as this repo's profile. Two profiles claiming one binary make the attachment ambiguous and the kernel confines with **neither** — `mariadbd` runs unconfined. Disable the distro profile (symlink it into `disable/` and unload it) before loading this one.
2. **Redis runs under `NoNewPrivileges=true`.** Ubuntu's `redis-server.service` sets `NoNewPrivileges=true`, which blocks the kernel's implicit path-based AppArmor attachment at `exec()` — the profile loads but Redis stays unconfined. systemd can still attach it explicitly (a privilege-reducing transition is allowed under NNP), so ship the `AppArmorProfile=` drop-in (`redis-server-apparmor.conf`). Under enforcement Redis then shows as the stacked label `/usr/sbin/redis-server//&unconfined`, which **is** enforced.

nginx and PHP-FPM attach cleanly by path with no extra step.

## What every profile enforces

1. **RCE shell block (`deny /bin/** x`)** — the confined daemon can never launch shells, compilers, or system utilities. Reverse shells and UDF/`SYSTEM`-style command execution die at the kernel.
2. **Write confinement** — writes are limited to each service's designated mutable paths only (uploads/cache for the web tier, `/var/lib/mysql` for the database, `/var/lib/redis` for the cache). WordPress core, plugin, and theme directories are explicitly `deny … w`, keeping code immutable at runtime.
3. **Socket isolation** — inter-service traffic is pinned to the expected local Unix sockets (`/run/php/php*.sock`, `/run/mysqld/mysqld.sock`, `/run/redis/redis-server.sock`). Redis additionally carries `deny network inet/inet6`, making its TCP port unreachable even if reconfigured.
4. **Credential shielding** — TLS certificates and origin keys are readable only where required, and nothing else on the filesystem is visible beyond each daemon's operational needs.

### Profile-specific notes

* **Nginx** — includes read/write access to `/var/lib/nginx/**` (client-body/proxy/fastcgi temp buffers); without it, large media uploads fail under enforcement. Write access inside the webroot is limited to `wp-content/uploads/`.
* **PHP-FPM** — a *named* profile (`profile php-fpm /usr/sbin/php-fpm* …`) covering any installed PHP 8.x FPM binary. Grants `owner /tmp/**` for upload staging, and socket access to MariaDB and Redis only. Outbound `inet stream` stays open for payment-gateway APIs (Stripe/PayPal); raw sockets are denied. If a plugin legitimately needs to write inside its own directory (translations, local logs), add that specific path before enforcing.
* **MariaDB** — data-directory confinement (`/var/lib/mariadb/** rwk` on Ubuntu 26.04, `/var/lib/mysql/** rwk` on older releases — both allowed) plus temp paths and the block-device geometry probes InnoDB reads at startup (`/sys/.../queue/*`, `/sys/block/`); every execution path on the system is denied, neutralizing SQL-injection→file-write→execute chains. Needs `attach_disconnected` for the systemd `Type=notify` readiness socket.
* **Redis** — socket-only operation enforced at two layers (config `port 0` + profile `deny network inet`), persistence limited to `/var/lib/redis`. Attached via the systemd drop-in (see gotcha #2) and needs `attach_disconnected` for the readiness socket under the unit's mount sandbox.

## Deployment

```bash
# 1. Copy the profiles to the AppArmor directory (names already match)
sudo cp apparmor/usr.sbin.* /etc/apparmor.d/

# 2. Disable the distro's own mariadbd profile (gotcha #1)
sudo mkdir -p /etc/apparmor.d/disable
sudo ln -sf /etc/apparmor.d/mariadbd /etc/apparmor.d/disable/mariadbd
sudo apparmor_parser -R /etc/apparmor.d/mariadbd 2>/dev/null || true

# 3. Parse and load each profile in enforce mode
for p in usr.sbin.nginx usr.sbin.php-fpm usr.sbin.mariadbd usr.sbin.redis-server; do
  sudo apparmor_parser -r -W "/etc/apparmor.d/$p"
done

# 4. Attach the Redis profile via systemd (gotcha #2 — NoNewPrivileges)
sudo mkdir -p /etc/systemd/system/redis-server.service.d
sudo cp apparmor/redis-server-apparmor.conf /etc/systemd/system/redis-server.service.d/apparmor.conf
sudo systemctl daemon-reload

# 5. Restart the confined services so they attach to their profiles
sudo systemctl restart nginx php8.5-fpm mariadb redis-server   # match your PHP version

# 6. Verify enforcement (all four should be in enforce mode)
sudo aa-status | grep -E "nginx|php-fpm|mariadbd|redis"
```

> Verified on a fresh **Ubuntu 26.04 / MariaDB 11.8 / Redis 8.0 / PHP 8.5** host:
> after the steps above, `verify-apparmor.sh` reports all four daemons **ENFORCED**
> with **zero** AVC denials during normal WordPress traffic. Note the Ubuntu 26.04
> data path is `/var/lib/mariadb` (older releases used `/var/lib/mysql`); the
> MariaDB profile allows both.

Validate any profile edit **before** loading it:

```bash
sudo apparmor_parser -Q -K apparmor/usr.sbin.nginx   # syntax check only, no load
```

## Rollout advice: complain first, then enforce

Put a profile in complain mode on a staging box, exercise the site (uploads, checkout, cron, updates), review denials, then enforce:

```bash
sudo aa-complain /etc/apparmor.d/usr.sbin.nginx   # log-only mode
# ... exercise the application, then review:
sudo journalctl -k | grep 'apparmor="ALLOWED"'
sudo aa-enforce /etc/apparmor.d/usr.sbin.nginx    # kernel-blocking mode
```

## Auditing violations

All denials are logged as AVC records (`apparmor="DENIED"`) in `/var/log/audit/audit.log` (with auditd) or the kernel log. This repo ships tooling for them:

* [`scripts/verify-apparmor.sh`](../scripts/verify-apparmor.sh) — enforcement/compliance audit ([docs](../docs/verify-apparmor.md))
* [`scripts/alert-apparmor-status.sh`](../scripts/alert-apparmor-status.sh) — denial sweeper with Discord/Slack alerts ([docs](../docs/alert-apparmor-status.md))
* [`docs/apparmor-cheat-sheet.md`](../docs/apparmor-cheat-sheet.md) — day-2 administration commands
* [`docs/apparmor-test-plan.md`](../docs/apparmor-test-plan.md) — staged validation plan

---

*Part of the [SafeCloud.PRO Hardened LEMP Stack](../README.md) · [safecloud.pro](https://safecloud.pro)*
