![SafeCloud.PRO](../docs/assets/wm-white.png)

# WordPress — Must-Use Hardening Plugin

Application-tier hardening that loads before every standard plugin and cannot be deactivated from the dashboard — so a compromised admin account can't switch it off.

## File

| File | Deploys to | License |
| :--- | :--- | :--- |
| `mu-plugins/safecloud-hardening.php` | `/var/www/html/wp-content/mu-plugins/` | GPLv2 or later (WordPress-standard) |

## What it enforces

1. **XML-RPC lockdown** — disables the XML-RPC interface and strips all its methods (a favorite brute-force amplification and DDoS vector). Pair with the [`nginx-wp-login` Fail2ban jail](../fail2ban/README.md) for firewall-level enforcement.
2. **User-enumeration blocking** — requires authentication for the REST `wp/v2/users` endpoint (matched on the canonical route via `rest_pre_dispatch`, so both `/wp-json/wp/v2/users` and the default-permalink `?rest_route=/wp/v2/users` form are covered — matching the raw request URI alone would miss the latter), blocks `?author=N` ID scanning, and strips author identity from oEmbed responses. Brute-force tools get no username list to work with.
3. **Generic login errors** — replaces "invalid username" / "incorrect password" feedback with a single generic message: zero signal about which usernames exist.
4. **Honeypot spam defense** — injects a CSS-hidden field into comment and WooCommerce review forms (plus Contact Form 7 validation). Bots fill it; humans never see it. Filled honeypot = instant 403, no database writes.
5. **SEO-balanced author hiding** — author archives get `noindex, follow, noarchive` instead of hard redirects, keeping them out of search indexes without breaking crawl structure or link equity.
6. **File-editor lockout** — enforces `DISALLOW_FILE_EDIT` as a second layer even if `wp-config.php` misses it.
7. **Version cloaking** — removes the WordPress generator version from HTML, feeds, and scripts.

## Design decisions

* **MU architecture:** must-use plugins execute on the lowest plugin tier, before standard plugins and themes.
* **Webhook exemptions:** WooCommerce/payment endpoints (`/wc-api/*`, `/wp-json/wc/`, Stripe, PayPal) are never filtered here — checkout reliability is a hard requirement, so payment webhooks can't hit false positives.
* **Optional aggressive mode:** `COMPREHENSIVE_HARDENING_AGGRESSIVE_MODE` (default `false`) blocks *all* unauthenticated REST traffic except the payment exemptions. Enable only after staging tests — some themes/plugins rely on public REST routes.
* **Edge pairing:** for challenge-based bot filtering (login forms, checkout), add Cloudflare Turnstile at the edge; key placeholders live in [`.env.example`](../.env.example).

## Deployment

```bash
sudo mkdir -p /var/www/html/wp-content/mu-plugins
sudo cp wordpress/mu-plugins/safecloud-hardening.php /var/www/html/wp-content/mu-plugins/
sudo chown www-data:www-data /var/www/html/wp-content/mu-plugins/safecloud-hardening.php
```

No activation needed — MU-plugins load automatically. Verify under **Dashboard → Plugins → Must-Use**.

---

*Part of the [SafeCloud.PRO Hardened LEMP Stack](../README.md) · [safecloud.pro](https://safecloud.pro)*
