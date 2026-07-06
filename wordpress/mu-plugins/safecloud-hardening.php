<?php
/**
 * Plugin Name: SafeCloud.PRO WordPress Hardening (MU)
 * Plugin URI: https://github.com/safecloudpro/hardened-lemp-stack
 * Description: Production-grade hardening: XML-RPC lockdown, user-enumeration blocking, generic login errors, honeypot spam defense, and SEO-balanced author-archive noindexing.
 * Version: 2.2.0
 * Author: SafeCloud.PRO
 * Author URI: https://safecloud.pro
 * License: GPLv2 or later
 *
 * DESIGN DECISION COMMENTARY:
 * 1. Must-Use (MU) Architecture: This runs before standard plugins, ensuring security policies are enforced early
 *    and cannot be disabled by a compromised administrator account in the dashboard.
 * 2. SEO-Balanced Security: Author archives are set to 'noindex, follow' instead of being flatly blocked. This hides
 *    the author list from search indexes (reducing the user harvesting vector) while preserving link equity.
 * 3. Specific Webhook Exemption: Webhook endpoints (/wc-api/*) are never filtered or blocked at this layer, ensuring
 *    payment processing remains fully reliable and never hits false positives.
 * 4. Zero-Trust Local Validation: All user input is treated as hostile. Comment and review forms are
 *    protected with a CSS-hidden honeypot field. Pair with Cloudflare Turnstile at the edge (see
 *    .env.example for the key placeholders) for challenge-based bot filtering on login forms.
 */

if (!defined('ABSPATH')) {
    exit; // Prevent direct access
}

// ==========================================
// 1. CONFIGURATION & CONSTANTS
// ==========================================
/**
 * Toggle AGGRESSIVE_MODE for ultra-high security setups.
 * WARNING: Enabling this will block all unauthenticated REST API requests except for whitelisted endpoints (like WooCommerce).
 * Set to true ONLY after thorough testing in staging.
 */
define('COMPREHENSIVE_HARDENING_AGGRESSIVE_MODE', false);

// Name of the comment honeypot field (looks like a valid field to trick automated spam bots)
define('WP_SECURITY_HONEYPOT_FIELD', 'user_phone_confirm_verify');

// ==========================================
// 2. FILE EDITING & XML-RPC DISABLING
// ==========================================
// These are standard hardening parameters that block common execution vectors.
// Note: DISALLOW_FILE_EDIT is best set in wp-config.php, but we enforce it here as an extra layer of defense.
if (!defined('DISALLOW_FILE_EDIT')) {
    define('DISALLOW_FILE_EDIT', true);
}

// Disable XML-RPC completely (often exploited for brute-force amplification and DDoS attacks)
add_filter('xmlrpc_enabled', '__return_false');
add_filter('xmlrpc_methods', function($methods) {
    return array(); // Strip out all available XML-RPC endpoints
});

// ==========================================
// 3. SECURE AUTHENTICATION & LOGIN HARDENING
// ==========================================
/**
 * Generic Login Error Messages.
 * Prevent admin leakage by removing specific errors like "invalid username" or "incorrect password".
 * This gives brute-force tools zero feedback on whether a username actually exists on the system.
 */
add_filter('login_errors', function($error) {
    return __('<strong>ERROR</strong>: The credentials entered are incorrect. Please try again.', 'wp-security-hardening');
});

// Remove the WordPress generator version number from header, feeds, and scripts (minimizes version disclosure)
add_filter('the_generator', '__return_empty_string');
remove_action('wp_head', 'wp_generator');

// Disable user enumeration via traditional oembed endpoints
add_filter('oembed_response_data', function($data) {
    if (isset($data['author_name'])) {
        unset($data['author_name']);
    }
    if (isset($data['author_url'])) {
        unset($data['author_url']);
    }
    return $data;
});

// ==========================================
// 4. ADVANCED USER ENUMERATION BLOCKING
// ==========================================
/**
 * Block REST API User Enumeration.
 * Attackers commonly harvest valid usernames by scanning the `wp/v2/users` resource.
 * IMPORTANT: this hooks rest_pre_dispatch and matches the CANONICAL route from the
 * REST request object — not $_SERVER['REQUEST_URI']. Matching the raw URI against
 * "/wp-json/..." is bypassable, because the same endpoint is always reachable as
 * "?rest_route=/wp/v2/users" (and that form is the default on plain permalinks).
 * Exception is made for WooCommerce endpoints to maintain integration capabilities.
 */
add_filter('rest_pre_dispatch', function($result, $server, $request) {
    if (!empty($result)) {
        return $result; // Respect an earlier short-circuit
    }

    // Canonical route, e.g. "/wp/v2/users" — identical for /wp-json/ and ?rest_route= forms
    $route = $request->get_route();

    // Require authentication for the user endpoints
    if (preg_match('#^/wp/v2/users(/|$)#', $route) && !is_user_logged_in()) {
        return new WP_Error(
            'rest_forbidden_user_enumeration',
            __('User enumeration is strictly prohibited for unauthenticated requests.', 'wp-security-hardening'),
            array('status' => 401)
        );
    }

    // Aggressive Mode: Block all unauthenticated REST requests, with critical exemptions (WooCommerce webhooks)
    if (COMPREHENSIVE_HARDENING_AGGRESSIVE_MODE && !is_user_logged_in()) {
        // Essential exclusions for webhooks, checkout, and standard payment integrations
        // (route prefixes; the legacy non-REST /wc-api/ endpoint never enters this dispatcher)
        $exemptions = array(
            '/wc/',
            '/wc-api/',
            '/stripe/',
            '/paypal/'
        );

        $is_exempt = false;
        foreach ($exemptions as $exemption) {
            if (strpos($route, $exemption) === 0) {
                $is_exempt = true;
                break;
            }
        }

        if (!$is_exempt) {
            return new WP_Error(
                'rest_unauthorized_aggressive_mode',
                __('Access to the REST API is restricted under Aggressive Security Mode.', 'wp-security-hardening'),
                array('status' => 401)
            );
        }
    }

    return $result;
}, 10, 3);

/**
 * Block query-string author scanning (?author=N).
 * Automated scanners crawl the site looking for author query params to map valid account IDs.
 * Instead of redirecting to the homepage (which can create infinite loop issues and breaks pagination),
 * we block the request if the author parameter is set and the request is unauthenticated.
 */
add_action('init', function() {
    if (!is_admin() && isset($_GET['author']) && !is_user_logged_in()) {
        wp_die(
            __('Direct author query enumeration is blocked for security purposes.', 'wp-security-hardening'),
            __('Security Blocked', 'wp-security-hardening'),
            array('response' => 403)
        );
    }
});

// ==========================================
// 5. SEO-FRIENDLY CONFIGURATION
// ==========================================
/**
 * SEO-Balanced Author Archive Hardening.
 * Hard redirects drop search engine index trust and break link juice flow.
 * Instead of redirects, we inject 'noindex, follow' on all author pages to keep them out of Google's index
 * while preserving internal structural integrity and index crawling properties.
 */
add_action('wp_head', function() {
    if (is_author()) {
        echo '<meta name="robots" content="noindex, follow, noarchive" />' . "\n";
    }
});

// ==========================================
// 6. COMMENT SPAM & HONEYPOT DEFENSE
// ==========================================
/**
 * Render Hidden Honeypot Field in Comment Forms.
 * This covers both standard WordPress blog posts and WooCommerce Product Reviews (which are comments).
 * The field is styled with CSS to remain completely invisible to human users, but automated spambots,
 * which parse the raw HTML, will populate it, triggering an instant block.
 */
add_action('comment_form_logged_in_after', 'wp_security_render_comment_honeypot');
add_action('comment_form_after_fields', 'wp_security_render_comment_honeypot');

function wp_security_render_comment_honeypot() {
    $field_name = WP_SECURITY_HONEYPOT_FIELD;
    echo <<<HTML
    <p class="comment-form-user-verification" style="display:none !important; visibility:hidden !important; position:absolute !important; left:-9999px !important;">
        <label for="{$field_name}">Please leave this field empty (Anti-Spam Verification)</label>
        <input type="text" id="{$field_name}" name="{$field_name}" value="" tabindex="-1" autocomplete="off" />
    </p>
HTML;
}

/**
 * Intercept and Validate Honeypot on Submission.
 * If the hidden honeypot field is filled, the request is immediately killed as a confirmed spam bot.
 */
add_filter('preprocess_comment', function($commentdata) {
    // Only apply to non-administrators
    if (current_user_can('manage_options')) {
        return $commentdata;
    }

    if (isset($_POST[WP_SECURITY_HONEYPOT_FIELD]) && !empty($_POST[WP_SECURITY_HONEYPOT_FIELD])) {
        // Fail silently or loudly. Loudly consumes less database resources during mass spam runs.
        wp_die(
            __('Spam transaction detected and terminated by defensive honeypot.', 'wp-security-hardening'),
            __('Spam Blocked', 'wp-security-hardening'),
            array('response' => 403)
        );
    }

    return $commentdata;
});

/**
 * Contact Form 7 Honeypot & Turnstile Integration Support.
 * If you use CF7, this action injects validation for the same honeypot field.
 */
add_filter('wpcf7_validate', function($result, $tags) {
    if (isset($_POST[WP_SECURITY_HONEYPOT_FIELD]) && !empty($_POST[WP_SECURITY_HONEYPOT_FIELD])) {
        $result->invalidate('fields', __('Spam submission detected.', 'wp-security-hardening'));
    }
    return $result;
}, 10, 2);
