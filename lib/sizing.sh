#!/usr/bin/env bash
# ==============================================================================
# lib/sizing.sh — shared memory-budget math for the SafeCloud.PRO LEMP stack
# ==============================================================================
# Sourced by setup.sh (install-time sizing) and tune-stack.sh (re-tuning an
# already-installed host). Keeping the arithmetic in one place guarantees both
# tools reach the SAME numbers for the same RAM, so a re-tune never fights the
# install.
#
# This file defines FUNCTIONS ONLY — sourcing it changes nothing on its own.
#
# compute_memory_budget() reads these globals from the caller (set them first):
#   DB_POOL_FORCED   true|false   — user pinned --db-pool
#   DB_POOL_SIZE     e.g. 1.5G    — the pinned value (only read when forced)
#   PHP_WORKERS      integer      — the pinned worker count (only read when forced)
#   PHP_WORKERS_FORCED true|false — user pinned --php-workers
# …and WRITES these globals back:
#   RESERVED_SYS_MB REDIS_MAXMEMORY_MB DB_POOL_MB PHP_WORKERS DB_POOL_SIZE
#
# Colour variables (RED/YELLOW/NC) are used for warnings if the caller defined
# them; they default to empty so the lib is safe under `set -u`.
# ==============================================================================

# Guard against double-sourcing.
[ -n "${__SAFECLOUD_SIZING_SH:-}" ] && return 0
__SAFECLOUD_SIZING_SH=1

# Parse a human size (1.5G, 512M, 262144K, or a bare integer = MB) into an
# integer number of megabytes.
size_to_mb() {
    local val="$1" mb
    if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?[Gg]$ ]]; then
        mb=$(awk -v g="${val%[Gg]}" 'BEGIN{printf "%d", g*1024}')
    elif [[ "$val" =~ ^[0-9]+(\.[0-9]+)?[Mm]$ ]]; then
        mb=$(awk -v m="${val%[Mm]}" 'BEGIN{printf "%d", m}')
    elif [[ "$val" =~ ^[0-9]+[Kk]$ ]]; then
        mb=$(( ${val%[Kk]} / 1024 ))
    elif [[ "$val" =~ ^[0-9]+$ ]]; then
        mb="$val"
    else
        mb=0
    fi
    echo "$mb"
}

# Clamp an integer to [lo, hi].
clamp() {
    local v=$1 lo=$2 hi=$3
    (( v < lo )) && v=$lo
    (( v > hi )) && v=$hi
    echo "$v"
}

# Pretty-print an integer MB as GB (one decimal).
mb_to_gb() { awk -v mb="$1" 'BEGIN{printf "%.1f", mb/1024}'; }

# MariaDB/InnoDB reject fractional size suffixes (e.g. "1.5G" → "Unknown suffix
# '.'"). Emit an integer-megabyte value with an 'M' suffix, which every MariaDB
# version accepts.
normalize_mysql_size() {
    local mb; mb=$(size_to_mb "$1"); [ "${mb:-0}" -lt 1 ] && mb=128; echo "${mb}M"
}

# ==============================================================================
# Adaptive memory budget.
# Derives every memory-sensitive setting from the RAM the host actually has, so
# the same math is safe on a 1 GB box and a 16 GB box. See globals contract at
# the top of this file.
# ==============================================================================
compute_memory_budget() {
    local total_mb="$1"
    local worker_rss_mb=50   # conservative avg RSS of a WordPress PHP-FPM worker

    # System reserve: 20% of RAM, floored at 256 MB (tiny boxes still need an OS)
    # and capped at 2048 MB (big boxes don't need more set aside for the OS).
    RESERVED_SYS_MB=$(clamp $(( total_mb * 20 / 100 )) 256 2048)

    # Redis cache cap: 15% of RAM, clamped to a sane [64, 1024] MB window, and
    # never more than 40% of what's left after the system reserve.
    local avail_after_sys=$(( total_mb - RESERVED_SYS_MB ))
    (( avail_after_sys < 0 )) && avail_after_sys=0
    REDIS_MAXMEMORY_MB=$(clamp $(( total_mb * 15 / 100 )) 64 1024)
    local redis_cap=$(( avail_after_sys * 40 / 100 ))
    (( REDIS_MAXMEMORY_MB > redis_cap )) && REDIS_MAXMEMORY_MB=$redis_cap
    (( REDIS_MAXMEMORY_MB < 32 )) && REDIS_MAXMEMORY_MB=32

    # InnoDB buffer pool.
    #   - Pinned (--db-pool): honored, but capped so it can't starve PHP.
    #   - Auto: 25% of RAM, scaled DOWN on small boxes, but capped at 1.5 GB.
    #     A WordPress/WooCommerce working set is ~300 MB, so a pool beyond ~1.5 GB
    #     just wastes RAM that PHP can use. Want more? Pass --db-pool explicitly.
    local auto_db_cap_mb=1536
    local avail_after_redis=$(( avail_after_sys - REDIS_MAXMEMORY_MB ))
    (( avail_after_redis < 0 )) && avail_after_redis=0
    if [ "${DB_POOL_FORCED:-false}" = "true" ]; then
        DB_POOL_MB=$(size_to_mb "$DB_POOL_SIZE")
        (( DB_POOL_MB < 1 )) && DB_POOL_MB=128
        local db_hard_cap=$(( avail_after_redis * 80 / 100 ))
        if (( db_hard_cap > 0 && DB_POOL_MB > db_hard_cap )); then
            echo -e "${YELLOW:-}[WARNING] --db-pool ${DB_POOL_SIZE} ($(mb_to_gb "$DB_POOL_MB") GB) is too large for this ${total_mb} MB host; capping to $(mb_to_gb "$db_hard_cap") GB so PHP/MySQL don't OOM.${NC:-}" >&2
            DB_POOL_MB=$db_hard_cap
        fi
    else
        # Upper bound = min(half the post-Redis budget, 1.5 GB), floored at 128.
        local db_upper=$(( avail_after_redis / 2 ))
        (( db_upper > auto_db_cap_mb )) && db_upper=$auto_db_cap_mb
        (( db_upper < 128 )) && db_upper=128
        DB_POOL_MB=$(clamp $(( total_mb * 25 / 100 )) 128 "$db_upper")
    fi

    # Whatever remains is PHP's. Worker count = budget / avg worker RSS, with a
    # 15% safety buffer, floored at 2 so the site can always serve a request.
    local php_alloc_mb=$(( total_mb - RESERVED_SYS_MB - REDIS_MAXMEMORY_MB - DB_POOL_MB ))
    local max_safe_workers=$(( php_alloc_mb > 0 ? php_alloc_mb / worker_rss_mb : 0 ))
    local recommended=$(( max_safe_workers * 85 / 100 ))
    (( recommended < 2 )) && recommended=2

    if [ "${PHP_WORKERS_FORCED:-false}" = "true" ]; then
        if (( php_alloc_mb > 0 && PHP_WORKERS > max_safe_workers )); then
            echo -e "${YELLOW:-}[WARNING] --php-workers ${PHP_WORKERS} exceeds the safe maximum (${max_safe_workers}) for this host's free RAM; keeping your value but expect OOM risk under load.${NC:-}" >&2
        fi
    else
        PHP_WORKERS=$recommended
    fi

    # Human-readable pool string for display/logging.
    DB_POOL_SIZE="$(mb_to_gb "$DB_POOL_MB")G"
}
