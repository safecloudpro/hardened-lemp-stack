#!/usr/bin/env bats
# ==============================================================================
# Unit tests for lib/sizing.sh — the RAM→budget math shared by setup.sh and
# tune-stack.sh. Run:  bats tests/    (or:  bats tests/sizing.bats)
# ==============================================================================

setup() {
    # shellcheck source=../lib/sizing.sh
    source "${BATS_TEST_DIRNAME}/../lib/sizing.sh"
    # Defaults the budget function reads from the caller.
    DB_POOL_FORCED=false; PHP_WORKERS_FORCED=false
    DB_POOL_SIZE=auto; PHP_WORKERS=0
    RESERVED_SYS_MB=0; REDIS_MAXMEMORY_MB=0; DB_POOL_MB=0
}

# ---- size_to_mb --------------------------------------------------------------
@test "size_to_mb: gigabytes with decimal" { [ "$(size_to_mb 1.5G)" -eq 1536 ]; }
@test "size_to_mb: whole gigabytes"        { [ "$(size_to_mb 2G)" -eq 2048 ]; }
@test "size_to_mb: megabytes"              { [ "$(size_to_mb 512M)" -eq 512 ]; }
@test "size_to_mb: kilobytes"              { [ "$(size_to_mb 262144K)" -eq 256 ]; }
@test "size_to_mb: bare integer is MB"     { [ "$(size_to_mb 2048)" -eq 2048 ]; }
@test "size_to_mb: garbage is 0"           { [ "$(size_to_mb notasize)" -eq 0 ]; }
@test "size_to_mb: lowercase suffix"       { [ "$(size_to_mb 1g)" -eq 1024 ]; }

# ---- clamp -------------------------------------------------------------------
@test "clamp: within range unchanged" { [ "$(clamp 500 100 1000)" -eq 500 ]; }
@test "clamp: below floor"            { [ "$(clamp 50 100 1000)" -eq 100 ]; }
@test "clamp: above ceiling"          { [ "$(clamp 5000 100 1000)" -eq 1000 ]; }

# ---- mb_to_gb ----------------------------------------------------------------
@test "mb_to_gb: 1536 -> 1.5" { [ "$(mb_to_gb 1536)" = "1.5" ]; }
@test "mb_to_gb: 512 -> 0.5"  { [ "$(mb_to_gb 512)" = "0.5" ]; }

# ---- normalize_mysql_size ----------------------------------------------------
@test "normalize_mysql_size: fractional G -> integer M" { [ "$(normalize_mysql_size 1.5G)" = "1536M" ]; }
@test "normalize_mysql_size: zero -> 128M floor"        { [ "$(normalize_mysql_size 0)" = "128M" ]; }

# ---- compute_memory_budget: 16 GB auto ---------------------------------------
@test "budget 16GB: system reserve capped at 2048" {
    compute_memory_budget 16384
    [ "$RESERVED_SYS_MB" -eq 2048 ]
}
@test "budget 16GB: redis capped at 1024" {
    compute_memory_budget 16384
    [ "$REDIS_MAXMEMORY_MB" -eq 1024 ]
}
@test "budget 16GB: InnoDB auto-capped at 1536" {
    compute_memory_budget 16384
    [ "$DB_POOL_MB" -eq 1536 ]
}
@test "budget 16GB: workers fit remaining RAM" {
    compute_memory_budget 16384
    # php_alloc = 16384-2048-1024-1536 = 11776 ; ~11776/50*0.85
    [ "$PHP_WORKERS" -ge 150 ] && [ "$PHP_WORKERS" -le 220 ]
}

# ---- compute_memory_budget: 1 GB tiny box ------------------------------------
@test "budget 1GB: reserve floored at 256" {
    compute_memory_budget 1024
    [ "$RESERVED_SYS_MB" -eq 256 ]
}
@test "budget 1GB: InnoDB floored at 128+" {
    compute_memory_budget 1024
    [ "$DB_POOL_MB" -ge 128 ]
}
@test "budget 1GB: at least 2 workers" {
    compute_memory_budget 1024
    [ "$PHP_WORKERS" -ge 2 ]
}
@test "budget 1GB: everything fits within total RAM" {
    compute_memory_budget 1024
    local used=$(( RESERVED_SYS_MB + REDIS_MAXMEMORY_MB + DB_POOL_MB ))
    [ "$used" -lt 1024 ]
}

# ---- pinned overrides --------------------------------------------------------
@test "pinned db-pool honored when it fits" {
    DB_POOL_FORCED=true; DB_POOL_SIZE=4G
    compute_memory_budget 16384
    [ "$DB_POOL_MB" -eq 4096 ]
}
@test "pinned db-pool capped when it would starve PHP" {
    DB_POOL_FORCED=true; DB_POOL_SIZE=20G
    compute_memory_budget 16384
    # hard cap = (avail_after_redis) * 80% ; must be well under 20480
    [ "$DB_POOL_MB" -lt 20480 ]
    [ "$DB_POOL_MB" -gt 1536 ]
}
@test "pinned php-workers honored verbatim" {
    PHP_WORKERS_FORCED=true; PHP_WORKERS=42
    compute_memory_budget 16384
    [ "$PHP_WORKERS" -eq 42 ]
}

# ---- monotonicity sanity -----------------------------------------------------
@test "bigger box never gets fewer workers than a smaller one (auto)" {
    compute_memory_budget 4096;  small=$PHP_WORKERS
    setup
    compute_memory_budget 16384; big=$PHP_WORKERS
    [ "$big" -ge "$small" ]
}
