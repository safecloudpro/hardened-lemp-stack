![SafeCloud.PRO](../docs/assets/wm-white.png)

# Fail2ban — Firewall-Layer Brute-Force Defense

Production Fail2ban jail and filter configurations that integrate the UFW firewall directly with Nginx traffic logs, dropping abusive clients **before** they consume PHP workers.

> ⚠️ **Behind Cloudflare, restore the real client IP first.** The `nginx-wp-login`
> jail bans the IP recorded in the nginx access log. If nginx logs Cloudflare's
> edge IPs (the default when proxied), the jail would **ban Cloudflare itself** and
> take the whole site down. Run **[`configure-cloudflare-realip.sh`](../configure-cloudflare-realip.sh)**
> (setup.sh does this automatically) so nginx logs the true `CF-Connecting-IP`
> before relying on this jail.

## Why ban at the firewall, not in PHP

Security plugins handle login failures at the **application layer**: every blocked request still spawns a PHP-FPM worker just to render a "Blocked" page. Under a real brute-force wave that erodes RAM until the Linux OOM-killer starts shooting services. Fail2ban instead scans logs in real time and drops the offender's packets at the **kernel/firewall layer (UFW)** — the attack never reaches Nginx again.

## Files

| File | Deploys to | Purpose |
| :--- | :--- | :--- |
| `jail.local` | `/etc/fail2ban/jail.local` | Jail definitions, ban policy, UFW ban action |
| `filter.d/nginx-wp-login.conf` | `/etc/fail2ban/filter.d/` | Matches failed `wp-login.php` / `xmlrpc.php` POSTs |
| `filter.d/nginx-apparmor.conf` | `/etc/fail2ban/filter.d/` | **Experimental** AVC-denial filter (see caveat) |

## Jails

1. **`nginx-wp-login`** *(enabled)* — watches the Nginx access log for POSTs to `wp-login.php`/`xmlrpc.php` that indicate a failed attempt (status 200/401/403). Five failures within 10 minutes bans the IP across ports 80/443 for 24 hours. Successful logins (302 redirects) are deliberately not counted, so real users signing in repeatedly are never banned.
2. **`nginx-apparmor`** *(disabled by default — experimental)* — intended to ban clients correlated with kernel AppArmor denials. **Honest caveat:** stock AVC records do not contain the remote client IP, so this jail only works with an enriched audit pipeline that appends a `target="<ip>"` field; on a default Ubuntu install it matches nothing. Use [`scripts/alert-apparmor-status.sh`](../scripts/alert-apparmor-status.sh) for AppArmor alerting instead, and enable this jail only after validating with `fail2ban-regex`.

## Deployment

```bash
# 1. Copy the jail settings and filters
sudo cp fail2ban/jail.local /etc/fail2ban/jail.local
sudo cp fail2ban/filter.d/nginx-wp-login.conf /etc/fail2ban/filter.d/
sudo cp fail2ban/filter.d/nginx-apparmor.conf /etc/fail2ban/filter.d/

# 2. IMPORTANT: whitelist your own static admin IPs first
#    (edit "ignoreip" in /etc/fail2ban/jail.local)

# 3. Reload Fail2ban and verify
sudo systemctl restart fail2ban
sudo fail2ban-client status
sudo fail2ban-client status nginx-wp-login
```

Test any filter against a live log before trusting it:

```bash
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/nginx-wp-login.conf
```

## Reporting

[`scripts/fail2ban-report.sh`](../scripts/fail2ban-report.sh) compiles ban statistics per jail (totals, top offending IPs) as terminal reports, JSON, or Discord/Slack digests — see [docs/fail2ban-report.md](../docs/fail2ban-report.md).

---

*Part of the [SafeCloud.PRO Hardened LEMP Stack](../README.md) · [safecloud.pro](https://safecloud.pro)*
