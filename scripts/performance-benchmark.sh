#!/usr/bin/env bash
# ==============================================================================
# Title: secure-lemp-performance-benchmark.sh
# Target OS: Ubuntu 26.04 LTS (ARM64 / Graviton t4g.xlarge)
# Target Environment: Hardened WordPress & WooCommerce Stack
# Version: 2.1.0
# Description: Automated, flag-driven benchmark and sizing audit tool.
# ==============================================================================

set -uo pipefail

# ANSI color codes for clean reporting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values
TARGET_URL="http://127.0.0.1/index.php"
CONCURRENCY=20
REQUESTS=1000
REDIS_SOCKET="/var/run/redis/redis-server.sock"
REDIS_PORT=6379
REDIS_HOST="127.0.0.1"
REDIS_TEST_COUNT=20000
OUTPUT_FILE=""
RUN_REDIS=true
RUN_HTTP=true
NO_COLOR=false

# Print usage instructions
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Benchmark tool for secure LEMP configurations on Ubuntu 26.04 LTS.

Options:
  -u, --url URL           Target URL for Nginx/PHP HTTP benchmark (Default: http://127.0.0.1/index.php)
  -c, --concurrency NUM   Concurrency level for load simulation (Default: 20)
  -n, --requests NUM      Total request count for load simulation (Default: 1000)
  -o, --output FILE       Write the uncolored report directly to a specified text file
  --only-redis            Only run Redis IPC (Unix domain socket vs TCP) latency comparison
  --only-http             Only run PHP-FPM web transaction benchmarks
  --no-color              Disable colored text terminal output
  -h, --help              Show this help menu and exit

Examples:
  ./performance-benchmark.sh -u https://safecloud.pro/ -c 50 -n 5000
  ./performance-benchmark.sh --only-redis -o /tmp/redis_latencies.txt
EOF
}

# Parse options
parse_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--url)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    TARGET_URL="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR] --url requires a value.${NC}" >&2
                    exit 1
                fi
                ;;
            -c|--concurrency)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    CONCURRENCY="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR] --concurrency requires a valid integer value.${NC}" >&2
                    exit 1
                fi
                ;;
            -n|--requests)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    REQUESTS="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR] --requests requires a valid integer value.${NC}" >&2
                    exit 1
                fi
                ;;
            -o|--output)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    OUTPUT_FILE="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR] --output requires a file path.${NC}" >&2
                    exit 1
                fi
                ;;
            --only-redis)
                RUN_REDIS=true
                RUN_HTTP=false
                shift
                ;;
            --only-http)
                RUN_REDIS=false
                RUN_HTTP=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR] Unknown option: $1${NC}" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

disable_colors() {
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
}

print_header() {
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "  ${BOLD}LEMP STACK PERFORMANCE BENCHMARK & SYSTEM AUDIT TOOL${NC}"
    echo -e "  Target Benchmark: ${TARGET_URL}"
    echo -e "  Trigger Time:     $(date)"
    echo -e "${CYAN}======================================================================${NC}"
}

check_dependencies() {
    echo -e "${BLUE}[*] Checking required system utilities...${NC}"
    
    HAS_AB=true
    if ! command -v ab &> /dev/null; then
        echo -e "${YELLOW}[!] 'ab' (ApacheBench) is not installed.${NC}"
        echo -e "    Required for HTTP profiling. Install via: ${BOLD}sudo apt-get install apache2-utils${NC}"
        HAS_AB=false
    else
        echo -e "${GREEN}[✓] ApacheBench (ab) is installed.${NC}"
    fi

    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}[ERROR] Python 3 is required to execute Redis raw-socket benchmarks.${NC}" >&2
        exit 1
    else
        echo -e "${GREEN}[✓] Python 3 is installed.${NC}"
    fi

    local php_ver
    php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    if [ -z "$php_ver" ]; then
        echo -e "${YELLOW}[!] Could not detect local PHP CLI runtime installation.${NC}"
    else
        echo -e "${GREEN}[✓] Detected PHP CLI Version: $php_ver${NC}"
    fi
}

# Redis domain socket vs loopback benchmarks using inline Python
run_redis_latency_benchmark() {
    echo -e "\n${CYAN}----------------------------------------------------------------------${NC}"
    echo -e "${BOLD}Phase 1: Redis IPC Mechanism Latency Comparison (${REDIS_TEST_COUNT} operations)${NC}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"

    python3 -c "
import socket
import time
import os

socket_path = '$REDIS_SOCKET'
tcp_host = '$REDIS_HOST'
tcp_port = int('$REDIS_PORT')
n = int('$REDIS_TEST_COUNT')

socket_exists = os.path.exists(socket_path)
tcp_listening = False
try:
    test_s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    test_s.settimeout(1.0)
    test_s.connect((tcp_host, tcp_port))
    tcp_listening = True
    test_s.close()
except:
    pass

set_cmd = b'*3\\r\\n\$3\\r\\nSET\\r\\n\$11\\r\\nbench_key_x\\r\\n\$11\\r\\nbench_val_x\\r\\n'
get_cmd = b'*2\\r\\n\$3\\r\\nGET\\r\\n\$11\\r\\nbench_key_x\\r\\n'
del_cmd = b'*2\\r\\n\$3\\r\\nDEL\\r\\n\$11\\r\\nbench_key_x\\r\\n'

def benchmark_connection(s):
    t0 = time.time()
    for _ in range(n):
        s.sendall(set_cmd)
        s.recv(1024)
        s.sendall(get_cmd)
        s.recv(1024)
    t1 = time.time()
    # Clean up the benchmark key so it never lingers in the production cache
    s.sendall(del_cmd)
    s.recv(1024)
    return t1 - t0

if tcp_listening:
    try:
        s_tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s_tcp.connect((tcp_host, tcp_port))
        tcp_time = benchmark_connection(s_tcp)
        s_tcp.close()
        tcp_ops = (n * 2) / tcp_time
        print(f'TCP_SUCCESS:{tcp_time:.4f}:{tcp_ops:.1f}')
    except Exception as e:
        print(f'TCP_ERROR:{str(e)}')
else:
    print('TCP_DISABLED:Port 6379 is not bound or accessible.')

if socket_exists:
    try:
        s_unix = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s_unix.connect(socket_path)
        unix_time = benchmark_connection(s_unix)
        s_unix.close()
        unix_ops = (n * 2) / unix_time
        print(f'UNIX_SUCCESS:{unix_time:.4f}:{unix_ops:.1f}')
    except Exception as e:
        print(f'UNIX_ERROR:{str(e)}')
else:
    print('UNIX_DISABLED:Unix socket path not found.')
" > /tmp/redis_perf_results.txt

    local tcp_ops=0
    local unix_ops=0

    if grep -q "TCP_SUCCESS" /tmp/redis_perf_results.txt; then
        local tcp_time
        tcp_time=$(grep "TCP_SUCCESS" /tmp/redis_perf_results.txt | cut -d':' -f2)
        tcp_ops=$(grep "TCP_SUCCESS" /tmp/redis_perf_results.txt | cut -d':' -f3)
        echo -e "${YELLOW}[TCP Loopback]${NC} Duration: ${tcp_time}s | Throughput: ${BOLD}${tcp_ops}${NC} ops/sec"
    else
        echo -e "${YELLOW}[TCP Loopback]${NC} Not benchmarked / Disabled"
    fi

    if grep -q "UNIX_SUCCESS" /tmp/redis_perf_results.txt; then
        local unix_time
        unix_time=$(grep "UNIX_SUCCESS" /tmp/redis_perf_results.txt | cut -d':' -f2)
        unix_ops=$(grep "UNIX_SUCCESS" /tmp/redis_perf_results.txt | cut -d':' -f3)
        echo -e "${GREEN}[Unix Socket]${NC}  Duration: ${unix_time}s | Throughput: ${BOLD}${unix_ops}${NC} ops/sec"

        # Output delta calculation if both succeeded (awk: no bc dependency)
        if awk -v t="$tcp_ops" -v u="$unix_ops" 'BEGIN{exit !(t>0 && u>0)}'; then
            local faster_pct
            faster_pct=$(awk -v t="$tcp_ops" -v u="$unix_ops" 'BEGIN{printf "%.1f", ((u-t)/t)*100}')
            echo -e "${GREEN}[ANALYSIS] Unix socket is ${BOLD}${faster_pct}% faster${NC} than loopback due to bypassed networking layers."
        fi
    else
        echo -e "${RED}[Unix Socket]${NC} Failed to establish a socket connection. Check service active state and permissions."
        echo -e "              Ensure 'www-data' user is added to 'redis' group: 'sudo usermod -aG redis www-data'"
    fi
}

run_php_fpm_benchmark() {
    echo -e "\n${CYAN}----------------------------------------------------------------------${NC}"
    echo -e "${BOLD}Phase 2: PHP-FPM Web Concurrency & Throughput Benchmark${NC}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"

    if [ "$HAS_AB" = "false" ]; then
        echo -e "${YELLOW}[!] Skipping HTTP load testing since ApacheBench (ab) was not found.${NC}"
        return
    fi

    echo -e "${BLUE}[*] Simulating load of ${REQUESTS} requests with a concurrency limit of ${CONCURRENCY}...${NC}"
    
    ab -n "$REQUESTS" -c "$CONCURRENCY" "$TARGET_URL" > /tmp/ab_results.txt 2>&1
    local ab_exit=$?

    if [ $ab_exit -ne 0 ]; then
        echo -e "${RED}[ERROR] ApacheBench execution failed. Diagnostic traces:${NC}"
        head -n 10 /tmp/ab_results.txt
        return
    fi

    # Extract metrics
    local rps
    rps=$(grep "Requests per second:" /tmp/ab_results.txt | awk '{print $4}')
    local lat
    lat=$(grep -m1 "Time per request:" /tmp/ab_results.txt | awk '{print $4}')
    local failed
    failed=$(grep "Failed requests:" /tmp/ab_results.txt | awk '{print $3}')
    local p50
    p50=$(grep -m1 "  50%" /tmp/ab_results.txt | awk '{print $2}')
    local p90
    p90=$(grep -m1 "  90%" /tmp/ab_results.txt | awk '{print $2}')
    local p99
    p99=$(grep -m1 "  99%" /tmp/ab_results.txt | awk '{print $2}')

    echo -e "${GREEN}[✓] HTTP Concurrency Benchmark Complete!${NC}"
    echo -e "    Throughput Rate:    ${BOLD}${rps} req/sec${NC}"
    echo -e "    Average Latency:    ${BOLD}${lat} ms${NC} (concurrent stream avg)"
    echo -e "    Failed Requests:    ${BOLD}${failed:-0}${NC}"
    echo -e "    Latency Distribution:"
    echo -e "      p50 (Median):      ${p50:-N/A} ms"
    echo -e "      p90:               ${p90:-N/A} ms"
    echo -e "      p99 (Tail):        ${p99:-N/A} ms"

    if [ -n "$failed" ] && [ "$failed" -gt 0 ]; then
        echo -e "${RED}[WARNING] Load simulation generated failed requests. Investigate PHP-FPM / Nginx error logs.${NC}"
    fi
}

check_php_fpm_pool_health() {
    echo -e "\n${CYAN}----------------------------------------------------------------------${NC}"
    echo -e "${BOLD}Phase 3: Sizing Audit & MariaDB Database Buffer Sizing${NC}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"

    # 1. Warn of process exhaustion
    local fpm_log
    fpm_log=$(find /var/log -name "php*-fpm.log" 2>/dev/null | head -n 1)
    if [ -n "$fpm_log" ] && [ -f "$fpm_log" ]; then
        local warnings
        warnings=$(grep -c "reached pm.max_children" "$fpm_log" 2>/dev/null || true)
        warnings=${warnings:-0}
        if [ "$warnings" -gt 0 ]; then
            echo -e "${RED}[WARNING] PHP-FPM process pool exhaustion reached its limit ${warnings} times in logs!${NC}"
            echo -e "          This creates queue stalling and 504 Gateway Timeout anomalies under spikes."
        else
            echo -e "${GREEN}[✓] No max_children exhaustion warnings detected in ${fpm_log}.${NC}"
        fi
    fi

    # 2. Sizing Verification & Saturated calculation
    local fpm_pids
    fpm_pids=$(pgrep -f "php-fpm: pool" 2>/dev/null || true)
    if [ -z "$fpm_pids" ]; then
        echo -e "${YELLOW}[!] No running FPM processes detected. Cannot calculate active memory profiles.${NC}"
    else
        local avg_ram
        avg_ram=$(ps -o rss= -p "$(echo "$fpm_pids" | tr '\n' ',' | sed 's/,$//')" | awk '{sum+=$1; count++} END {if (count > 0) print int(sum/count/1024); else print 0}')
        echo -e " Active Workers:         ${BOLD}$(echo "$fpm_pids" | wc -l)${NC}"
        echo -e " Avg RAM per Worker:     ${BOLD}${avg_ram} MB${NC}"

        # Get DB Buffer Sizing details (MariaDB 11 ships the "mariadb" client)
        local db_client="mariadb"
        command -v "$db_client" &>/dev/null || db_client="mysql"
        local pool_size_bytes
        pool_size_bytes=$("$db_client" -N -s -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | awk '{print $2}' | head -n 1)
        [[ "$pool_size_bytes" =~ ^[0-9]+$ ]] || pool_size_bytes=0
        local pool_size_mb=$((pool_size_bytes / 1024 / 1024))

        # Check Active Table and Index disk footprint
        local db_size_mb
        db_size_mb=$("$db_client" -N -s -e "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1024 / 1024, 0), 0) FROM information_schema.TABLES;" 2>/dev/null | awk '{print int($1)}' | head -n 1)
        [[ "$db_size_mb" =~ ^[0-9]+$ ]] || db_size_mb=0

        echo -e "\n ${BOLD}[MariaDB Sizing Verification]${NC}"
        echo -e "  - Configured Buffer Pool Size:  ${BOLD}${pool_size_mb} MB${NC}"
        echo -e "  - Active DB Table/Index Size:   ${BOLD}${db_size_mb} MB${NC}"

        if [ "$pool_size_mb" -gt 0 ]; then
            local usage_ratio
            usage_ratio=$((db_size_mb * 100 / pool_size_mb))
            echo -e "  - Buffer Cache Occupancy:       ${BOLD}${usage_ratio}%${NC}"
            if [ "$usage_ratio" -ge 80 ]; then
                echo -e "  ${RED}[WARNING] Database size exceeds 80% of your Buffer Pool cache ceiling!${NC}"
                echo -e "            Increase 'innodb_buffer_pool_size' in setup config to prevent slow disk read cycles."
            else
                echo -e "  - Cache Sizing Margin:          ${GREEN}PASS (Healthy Memory headroom remains)${NC}"
            fi
        fi
    fi
}

# Main script thread
parse_options "$@"

if [ "$NO_COLOR" = "true" ] || [ ! -t 1 ]; then
    disable_colors
fi

# Capture stdout if output target is specified
if [ -n "$OUTPUT_FILE" ]; then
    echo -e "[*] Writing benchmark results directly to: ${BOLD}${OUTPUT_FILE}${NC}"
    disable_colors
    # Redirect all stdout/stderr from this block into the file
    exec > "$OUTPUT_FILE" 2>&1
fi

print_header
check_dependencies

if [ "$RUN_REDIS" = "true" ]; then
    run_redis_latency_benchmark
fi

if [ "$RUN_HTTP" = "true" ]; then
    run_php_fpm_benchmark
fi

check_php_fpm_pool_health

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "  ${BOLD}Audit Complete! Use these metrics to continuously optimize configurations.${NC}"
echo -e "${CYAN}======================================================================${NC}\n"