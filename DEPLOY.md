![SafeCloud.PRO](docs/assets/wm-white.png)

# Deployment Runbook — Certificate → Connectivity → WordPress

This runbook takes a box that has **already run `setup.sh`** (Nginx, PHP‑FPM, MariaDB,
and Redis installed and hardened) and brings a live WordPress site up behind
Cloudflare, in the order that avoids the errors this stack is prone to.

Follow the steps top to bottom. Two helper scripts do the heavy lifting:

| Script | What it does |
|---|---|
| `install-cloudflare-cert.sh` | Validates and installs a Cloudflare **Origin Certificate** + key, wires Nginx to it, reloads. |
| `wordpress-provision.sh` | Creates the WordPress database + user, secures MariaDB (local‑only), installs the latest WordPress, writes `wp-config.php`. |

Both scripts must be run as **root** (`sudo`) from the directory that contains them
(examples below assume `~/hardened-lemp-stack/`).

---

## Prerequisites

- `setup.sh` completed successfully — `systemctl is-active nginx php*-fpm mariadb redis-server` all report `active`.
- You are on the origin box (e.g. an EC2 instance) with a sudo‑capable shell (SSM session is fine).
- Your domain is in Cloudflare with a **proxied (orange‑cloud) A record** pointing at the origin's public IP.
- You have console access to both the **Cloudflare dashboard** and the **AWS EC2 console** (for the Security Group).

> Throughout, replace `example.com` with your real domain.

---

## Step 1 — Install the origin TLS certificate

Cloudflare validates the origin certificate in **Full (strict)** mode, so install a
real Cloudflare Origin Certificate rather than leaving the self‑signed placeholder.

1. In Cloudflare: **SSL/TLS → Origin Server → Create Certificate**. Accept the
   defaults (RSA, hostnames `example.com, *.example.com`, 15 years). Cloudflare shows
   you an **Origin Certificate** and a **Private Key** — keep the page open.
2. On the box, run:

   ```bash
   sudo ~/hardened-lemp-stack/install-cloudflare-cert.sh
   ```

3. When prompted:
   - **Domain:** `example.com`
   - **Certificate:** paste the Origin Certificate block (visible on screen — it's public).
   - **Private key:** paste the Private Key block. **Input is hidden** — you'll see one
     `*` per line, not the key text.

The script validates the certificate and key, confirms they match, installs them to
`/etc/nginx/certs/example.com.pem` (644) and `.key` (600, root‑only), repoints the
Nginx `ssl_certificate` / `ssl_certificate_key` directives, runs `nginx -t`, and
reloads. If the config test fails it **rolls back automatically**, so a bad paste
can't take the site down.

---

## Step 2 — Set the Cloudflare SSL/TLS mode

Now that the origin presents a trusted certificate:

- Cloudflare → **SSL/TLS → Overview → Full (strict)**.

> If you ever see error **526** after this, the origin cert isn't trusted — re‑run
> Step 1, or temporarily drop to **Full** (not strict) to confirm the rest of the path.

---

## Step 3 — Open the network path to the origin

Cloudflare must be able to reach the box on **443**. There are two firewalls; UFW is
already open from `setup.sh`, but the **AWS Security Group is a separate gate**.

1. EC2 console → your instance → **Security** → the attached **Security Group** →
   **Edit inbound rules** → allow **HTTPS / TCP 443** (and **80**). Use source
   `0.0.0.0/0` to test, then tighten to
   [Cloudflare's IP ranges](https://www.cloudflare.com/ips/).
2. Confirm the Cloudflare **A record IP matches the instance's public IP**:

   ```bash
   TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 120")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4; echo
   ```

   If they differ, update the record. Attach an **Elastic IP** so the address doesn't
   drift on the next stop/start (a common cause of intermittent **522** errors).

---

## Step 4 — Verify origin reachability

Prove the origin answers locally (this bypasses Cloudflare and both firewalls):

```bash
curl -kI https://127.0.0.1/ -H 'Host: example.com'
```

Expect a fast `HTTP/2 200`, `301`, `302`, or `404` — **not** a hang and **not** `400`.

- A **hang** or Cloudflare **522** → network path (Step 3: Security Group / DNS).
- A **400 "No required SSL certificate was sent"** → Authenticated Origin Pulls is
  enforced but Cloudflare isn't sending a client cert. Handle it in Step 5.

---

## Step 5 — Authenticated Origin Pulls (mTLS)

`setup.sh` may have enabled origin‑side mutual TLS (`ssl_verify_client on`). Unless
you've turned Authenticated Origin Pulls **on in Cloudflare**, that rejects every
proxied request with a `400`. Check:

```bash
grep -n ssl_verify_client /etc/nginx/sites-available/wordpress
```

**To get the site working now,** disable enforcement until Cloudflare is ready:

```bash
sudo sed -i -E '/^[[:space:]]*(ssl_client_certificate|ssl_verify_client)\b/ s/^([[:space:]]*)/\1# /' \
  /etc/nginx/sites-available/wordpress
sudo nginx -t && sudo systemctl reload nginx
```

**To enable it properly later (recommended hardening), do it in this order:**

1. Cloudflare → **SSL/TLS → Origin Server → Authenticated Origin Pulls → On**.
2. Uncomment the two lines above (`ssl_client_certificate` points at the CA
   `setup.sh` already saved to `/etc/nginx/certs/cloudflare.crt`).
3. `sudo nginx -t && sudo systemctl reload nginx`.

Doing it in the reverse order locks Cloudflare out and produces a `400`/`525`.

---

## Step 6 — Install WordPress

```bash
sudo ~/hardened-lemp-stack/wordpress-provision.sh
```

You'll be asked, in order, for:

1. **WordPress database name** to create (e.g. `wordpress`).
2. **MariaDB username** for that database (e.g. `wp_user`).
3. **Password** for that user (entered twice, hidden).
4. **New MariaDB root password** (entered twice, hidden).

The script then:

- creates the database and the user, and grants that user full rights on **only** that database;
- secures MariaDB — removes anonymous users, disallows remote root, drops the `test`
  database, and enforces **local‑only** access (`bind-address = 127.0.0.1`);
- downloads the latest WordPress into `/var/www/html` (the nginx + AppArmor default;
  use `--webroot /path` to change it);
- writes `wp-config.php` wired to the database user/password, with fresh salts;
- sets `www-data` ownership and sane permissions (`wp-config.php` is `640`).

> It creates the database **before** changing the root password, so if anything fails
> it stops before touching root or WordPress.

---

## Step 7 — Point Nginx at the WordPress webroot (only if you changed it)

With the default webroot (`/var/www/html`) this step is **not needed** — it already
matches the `root` in `setup.sh`'s nginx config and the paths allowed by the nginx
AppArmor profile, and the provision script confirms this at the end.

Only if you installed WordPress somewhere else (`--webroot /path`), repoint nginx —
and add matching read rules to the nginx AppArmor profile, since it confines nginx to
`/var/www/html` by default:

```bash
sudo sed -i 's#root .*;#root /path/to/webroot;#' /etc/nginx/sites-available/wordpress
sudo nginx -t && sudo systemctl reload nginx
```

---

## Step 8 — Harden the WordPress configuration

Apply the application‑layer hardening before you expose the site:

```bash
sudo ~/hardened-lemp-stack/harden-wordpress.sh
```

This injects `wp-config.php` security constants (forces admin over TLS, disables the
dashboard file editor, blocks unfiltered HTML, turns off debug output), locks file
ownership/permissions (code tree owned by **root**, only `wp-content/uploads` and
`cache` stay web‑writable), removes version‑disclosure files (`readme.html`,
`license.txt`, …), and deploys the SafeCloud **MU‑plugin** so hardening loads before
any plugin. It's idempotent, backs up `wp-config.php`, and validates the result with
`php -l`.

> `harden-wordpress.sh` defaults to `--webroot /var/www/html`. It also sets
> `DISALLOW_FILE_MODS` *and* makes the code tree root‑owned, so the dashboard updater
> is disabled by design — to update, re‑run with `--allow-updates` (which restores
> `www-data` ownership), update, then re‑run without it to re‑lock. Full details in
> **[HARDEN-WORDPRESS.md](HARDEN-WORDPRESS.md)**.

> **Enable the Redis object cache _before_ this step** (while the code tree is still
> writable), or pass `--force` to the enabler afterwards:
> ```bash
> sudo ~/hardened-lemp-stack/enable-redis-cache.sh    # installs the drop-in over the hardened socket
> ```
> It restarts PHP‑FPM so OPcache (`validate_timestamps=0`) picks up the new config.
> Confirm with `sudo wp --allow-root redis status` → **Connected**.

---

## Step 9 — Restore the real visitor IP (Cloudflare)

`setup.sh` already ran `configure-cloudflare-realip.sh`, but re‑run it any time
Cloudflare updates its ranges — it writes `/etc/nginx/conf.d/cloudflare-realip.conf`
so nginx logs the true client IP:

```bash
sudo ~/hardened-lemp-stack/configure-cloudflare-realip.sh
```

> **Why it matters:** behind Cloudflare, without this nginx sees a Cloudflare edge
> IP as the client. The `nginx-wp-login` Fail2ban jail bans the IP in the access
> log — so without real‑IP restoration a brute‑force wave would make Fail2ban
> **ban Cloudflare itself**, taking the whole site offline.

---

## Step 10 — Finish the install

Open **https://example.com/** in a browser. You should get the WordPress setup
wizard — enter the site title and admin account, and you're live behind Cloudflare
with a hardened origin.

---

## Quick error reference

| Symptom | Meaning | Where to look |
|---|---|---|
| Cloudflare **522** | Can't open TCP to origin | Step 3 — Security Group / DNS / Elastic IP |
| Cloudflare **525** | TLS handshake failed | Step 5 — AOP enabled before Cloudflare was ready |
| Cloudflare **526** | Origin cert not trusted | Step 1 / Step 2 — install origin cert, or drop to Full |
| **400** "No required SSL certificate was sent" | Origin mTLS on, no client cert | Step 5 — disable `ssl_verify_client` or enable AOP in Cloudflare |
| `curl` to origin hangs | Nginx/PHP not responding | Check webroot (Step 7), `systemctl status nginx php*-fpm` |
| WordPress "Error establishing a database connection" | Wrong DB creds / DB down | Re‑check the values from Step 6; `systemctl status mariadb` |

---

### One‑glance order

```
setup.sh  ✅ (already done)
   │
   ├─ 1. install-cloudflare-cert.sh   → origin cert installed, nginx reloaded
   ├─ 2. Cloudflare SSL/TLS = Full (strict)
   ├─ 3. AWS Security Group: allow 443/80 ; DNS → origin IP (Elastic IP)
   ├─ 4. curl -kI https://127.0.0.1/    → verify origin answers
   ├─ 5. Authenticated Origin Pulls: off for now (enable later, CF first)
   ├─ 6. wordpress-provision.sh        → DB + user + secured MariaDB + WordPress (/var/www/html)
   ├─ 7. (only if --webroot changed) repoint nginx root + AppArmor rules
   ├─ 8. harden-wordpress.sh           → wp-config constants, perms, MU-plugin
   └─ 9. finish install in the browser
```
