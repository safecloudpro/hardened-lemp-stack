![SafeCloud.PRO](docs/assets/wm-white.png)

# Contributing to SafeCloud.PRO Hardened LEMP Stack

Thank you for your interest in contributing to the **SafeCloud.PRO** open-source security baselines! We welcome contributions from DevOps engineers, security researchers, and systems administrators to make our cloud environments safer and more resilient.

As a production-grade security repository, we maintain a highly disciplined development workflow to prevent configuration regression, credential leakages, or security vulnerabilities.

---

## 🔒 Security & Vulnerability Disclosure Policy (VDP)

**DO NOT OPEN A PUBLIC GITHUB ISSUE FOR SECURITY VULNERABILITIES.**

If you discover a potential security vulnerability, configuration bypass, or cryptographic weakness within these scripts or profiles, please report it privately:
1. Email your findings directly to **dev@safecloud.pro**.
2. Provide a detailed proof of concept (PoC) or reproduction steps.

We adhere to coordinated vulnerability disclosure and will work with you to patch and validate the issue promptly before publishing a CVE.

---

## 🛠 Guidelines for Contributions

We welcome improvements across all sections of this repository, including:
*   **Operating System & Substrate Hardening** (`setup.sh`, `monitoring/` systemd units, `apparmor/` profiles).
*   **Security Auditing & Observability** (`scripts/` audit tooling, Prometheus metrics).
*   **Perimeter Defense** (`fail2ban/` jails and filters).
*   **Application & CMS Containment** (`wordpress/mu-plugins/safecloud-hardening.php` optimizations).
*   **Automation Pipelines & Quality Gates** (GitHub Actions, validation suites).

### 1. Zero Hardcoded Credentials & Secrets Isolation
*   **No credentials or static parameters** may ever be committed to any repository fork.
*   Always use local environment variable abstractions (using `.env.example` as your baseline config).
*   For AWS cloud integrations, verify that the scripts leverage **AWS Secrets Manager with the Workload Credentials Provider** to dynamically acquire temporary credentials.

### 2. Mandatory Code Validation Standards
Before submitting a pull request, your contributions must pass our local linting gates (which are enforced automatically on the server-side via our CI pipelines):
*   **Shell Scripts (`.sh`)**: All scripts must be checked with `shellcheck` and show zero warnings or syntax errors.
*   **WordPress Must-Use Plugin (`.php`)**: Must conform strictly to `PHPCS` (WordPress Coding Standards) and contain no dynamic, unsanitized SQL statements (preventing SQL injection pathways).
*   **AppArmor Profiles (`apparmor/usr.sbin.*`)**: Must parse cleanly with the local AppArmor engine (`apparmor_parser -Q -K <profile>`) without compilation failures.

---

## 🔬 Local Development and Testing Playbook

To test modifications locally before submitting your pull request:

1.  **Fork and Clone:**
    ```bash
    git clone https://github.com/safecloudpro/hardened-lemp-stack.git
    cd hardened-lemp-stack
    ```
2.  **Verify Shell Syntax:**
    ```bash
    shellcheck setup.sh scripts/*.sh
    ```
3.  **Validate AppArmor Compilations (syntax check, no kernel load):**
    ```bash
    sudo apparmor_parser -Q -K apparmor/usr.sbin.nginx
    ```
4.  **Lint the MU-plugin:**
    ```bash
    php -l wordpress/mu-plugins/safecloud-hardening.php
    ```
5.  **Execute Local Status Scans:**
    Verify your audit reports return clean states by running:
    ```bash
    sudo ./scripts/status-report.sh --no-color
    ```

---

## ⚖ License

By contributing to this repository, you agree that your contributions will be licensed under the **Apache License 2.0** of the project.
