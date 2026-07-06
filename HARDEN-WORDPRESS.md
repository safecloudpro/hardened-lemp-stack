![SafeCloud.PRO](docs/assets/wm-white.png)

# WordPress Configuration Hardening — `harden-wordpress.sh`

`setup.sh` hardens the operating system and the LEMP services; `harden-wordpress.sh`
hardens **WordPress itself** — the `wp-config.php` constants, file permissions,
information disclosure, and the must-use plugin. Run it once, after WordPress is
installed (`wordpress-provision.sh`), and re-run it any time — it's idempotent.

```bash
sudo ~/hardened-lemp-stack/harden-wordpress.sh
```

By default it targets `/var/www/html`. Use `--webroot /path` if WordPress lives
elsewhere.

---

## What it changes

### 1. Security constants in `wp-config.php`

The script writes a single **managed block** (between clearly marked delimiters)
just before the `require_once … wp-settings.php` line. Every value uses
`defined() || define()`, so it never collides with a constant WordPress or your
config already set, and the block is rewritten — not duplicated — on each run.

| Constant | Value | Why |
|---|---|---|
| `FORCE_SSL_ADMIN` | `true` | Forces wp-admin and login over HTTPS (safe here because Cloudflare talks to the origin over TLS in Full/strict). |
| `DISALLOW_FILE_EDIT` | `true` | Removes the built-in theme/plugin **code editor** so a stolen admin session can't edit PHP from the dashboard. |
| `DISALLOW_FILE_MODS` | `true` | Blocks installing/updating/deleting plugins, themes, and core from the dashboard — matches the AppArmor profile that makes those directories read-only. See the updates note below. |
| `AUTOMATIC_UPDATER_DISABLED` | `true` | Turns off background auto-updates (which can't write to the read-only code dirs anyway). |
| `DISALLOW_UNFILTERED_HTML` | `true` | Stops even administrators from posting unfiltered HTML/JS (blocks stored-XSS via content). |
| `WP_DEBUG`, `WP_DEBUG_DISPLAY`, `WP_DEBUG_LOG` | `false` | No error output or debug logging in production (prevents path/credential disclosure). |
| `WP_POST_REVISIONS` | `5` | Caps revision bloat in the database. |
| `EMPTY_TRASH_DAYS` | `7` | Purges trashed content weekly. |
| `@ini_set('display_errors','0')` | — | Belt-and-suspenders: never render PHP errors to visitors. |

With `--allow-updates`, `DISALLOW_FILE_MODS` is set to `false` and
`WP_AUTO_UPDATE_CORE` to `'minor'` instead — use this only if you want to manage
plugins/updates from the dashboard rather than via a deploy pipeline.

### 2. File ownership and permissions

By default (locked down), code is owned by **`root`** and only *readable* by the web
user, so even outside PHP (whose AppArmor profile already denies these writes)
`www-data` cannot modify `wp-admin`, `wp-includes`, or the plugin/theme directories:

- Code tree owned by **`root:www-data`** (group-readable, not group-writable).
- **`wp-config.php` is `640`**, owned `root:www-data` — not world-readable, but PHP-FPM (running as `www-data`) still reads it via the group.
- Directories `755`, files `644`.
- Only the runtime dirs stay web-writable: **`wp-content/uploads`** and **`wp-content/cache`** are (re)created and `chown`ed to `www-data:www-data`.

With **`--allow-updates`**, the whole tree reverts to **`www-data:www-data`** so the
dashboard/auto updater can write to the code directories (`wp-config.php` becomes
`www-data`-owned too) — the trade-off described at the end of this document.

### 3. Information-disclosure cleanup

Removes files that leak the WordPress version or aren't needed in production:
`readme.html`, `license.txt`, `wp-config-sample.php`, and the default
`wp-content/plugins/hello.php` (Hello Dolly).

### 4. SafeCloud MU-plugin

Deploys `wordpress/mu-plugins/safecloud-hardening.php` into
`wp-content/mu-plugins/`. Must-use plugins load **before** all standard plugins and
**cannot be disabled from the dashboard**, so its protections (XML-RPC off, user
enumeration blocked, generic login errors, etc.) stay active even if an admin
account is compromised. Point at a different copy with `--mu-plugin PATH`.

### 5. Optional: salt rotation

`--rotate-salts` fetches a fresh set of authentication keys/salts from the WordPress
API and replaces them in `wp-config.php`. This **logs every user out** (existing
cookies become invalid), so use it after a suspected credential leak, not casually.

---

## Options

| Flag | Effect |
|---|---|
| `--webroot PATH` | WordPress install directory (default `/var/www/html`). |
| `--mu-plugin PATH` | Path to the MU-plugin to deploy. |
| `--allow-updates` | Permit dashboard/auto updates (relaxes `DISALLOW_FILE_MODS`). |
| `--rotate-salts` | Regenerate auth salts (logs everyone out). |
| `-h`, `--help` | Usage. |

---

## Safety & idempotency

- **Backup first.** `wp-config.php` is copied to `wp-config.php.bak.<timestamp>` before any edit.
- **Validated.** If `php` is available, the edited config is checked with `php -l`; on failure the backup is restored automatically and the script exits non-zero.
- **Repeatable.** The managed block is delimited and rewritten in place, so running the script many times leaves exactly one block.

---

## The updates trade-off (read this)

`DISALLOW_FILE_MODS = true` is deliberate: this stack keeps plugin/theme/core
directories **immutable** (root-owned on disk *and* read-only under AppArmor) so a
compromised dashboard can't install a malicious plugin. The cost is that the
dashboard's one-click updater is disabled. Update through a controlled path instead:

```bash
# Temporarily unlock, update, then re-lock:
sudo ./harden-wordpress.sh --allow-updates      # code tree → www-data-owned
sudo -u www-data wp core update   --path=/var/www/html
sudo -u www-data wp plugin update --all --path=/var/www/html
sudo ./harden-wordpress.sh                        # re-lock (code tree → root-owned)
```

Because the default run makes the code tree **root-owned**, running WP-CLI as
`www-data` cannot write to it until you re-run with `--allow-updates` first (or run
the updater as root). If you'd rather manage updates from the dashboard long-term,
keep `--allow-updates` in effect (and understand the code directories then stay
writable by the web user).

---

## Where this fits

```
setup.sh                     → OS + Nginx + PHP-FPM + MariaDB + Redis hardened
install-cloudflare-cert.sh   → origin TLS certificate
wordpress-provision.sh       → database + user + WordPress installed
harden-wordpress.sh          → THIS: wp-config, permissions, disclosure, MU-plugin
```

See **[DEPLOY.md](DEPLOY.md)** for the full end-to-end deployment order.
