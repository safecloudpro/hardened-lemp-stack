![SafeCloud.PRO](assets/wm-white.png)

# performance-benchmark.sh: Hardened LEMP & Redis Socket Performance Benchmark Tool
### Version 2.1.0 (SafeCloud.PRO Performance & Audit Suite)

`performance-benchmark.sh` is an advanced system-level audit, profiling, and capacity diagnostic tool designed to test the performance and resource efficiency of your hardened LEMP stack. 

It provides detailed latency distribution metrics, benchmarks the speed advantage of your **Redis Unix Socket** over TCP loopback, and actively audits MariaDB memory-to-disk cache occupancy ratios.

---

## Benchmarking & Diagnostic Phases

### Phase 1: Redis IPC Latency Comparison
* **The Operation:** Runs an inline Python 3 script that uses raw socket connections (`AF_UNIX` and `AF_INET`) to execute **20,000 SET and GET protocol operations**. This design is completely self-contained and requires no third-party libraries.
* **The Diagnostic Output:** Measures the duration and throughput of both transport mechanisms, calculating the precise speed percentage advantage of direct-memory Unix domain socket connections over the network loopback stack.

### Phase 2: PHP-FPM Web Concurrency & Throughput
* **The Operation:** Utilizes ApacheBench (`ab`) to run a custom load of requests against a target PHP endpoint.
* **The Diagnostic Output:** Measures Requests Per Second (RPS) throughput and captures the exact latency distribution percentiles (**p50 median, p90, and p99 tail-latencies**), letting you know how your web application behaves during load spikes.

### Phase 3: PHP-FPM Pool Health & MariaDB Cache Sizing
* **The Operation:** Scans the active process table (`ps`, `pgrep`) to calculate the exact average RAM footprint of running WordPress workers. It then connects to MariaDB to read the live `innodb_buffer_pool_size` and the actual physical database tables on disk.
* **The Sizing Advisor:** Alerts you if your physical database files are occupying **80% or more of your InnoDB buffer pool size**. It calculates the perfect `pm.max_children` setting tailored specifically to your active worker memory sizes and database footprint:
  $$\text{Safe Max Children} = \frac{\text{Total RAM} - \text{InnoDB Buffer Pool} - \text{Redis Pool} - \text{System Reserved}}{\text{Average Active Worker RAM}} \times 0.85 \text{ (15% safety buffer)}$$

---

## Usage Guide & Command Line Flags

```bash
./scripts/performance-benchmark.sh [OPTIONS]
```

### Available Options

| Option | Flag | Description |
| :--- | :--- | :--- |
| `--url URL` | `-u` | Target PHP URL path for Nginx/PHP-FPM benchmarking (Default: `http://127.0.0.1/index.php`). |
| `--concurrency NUM`| `-c` | ApacheBench concurrent client simulation stream limit (Default: `20`). |
| `--requests NUM` | `-n` | Total number of HTTP requests to execute under load simulation (Default: `1000`). |
| `--output FILE` | `-o` | Saves the uncolored, plain text benchmark report directly to a specified file. |
| `--only-redis` | *None* | Runs only the Redis domain socket vs. TCP loopback latency comparison phase. |
| `--only-http` | *None* | Runs only the Nginx/PHP-FPM ApacheBench load testing phase. |
| `--no-color` | *None* | Disables colors in the terminal report. |
| `--help` | `-h` | Opens the benchmark helper documentation. |

---

## Sample Report Format

```text
======================================================================
  LEMP STACK PERFORMANCE BENCHMARK & SYSTEM AUDIT TOOL
  Target Benchmark: http://127.0.0.1/index.php
  Trigger Time:     Thu Jul  2 12:56:50 PDT 2026
======================================================================
[*] Checking required system utilities...
[✓] ApacheBench (ab) is installed.
[✓] Python 3 is installed.
[✓] Detected PHP CLI Version: 8.4

----------------------------------------------------------------------
Phase 1: Redis IPC Mechanism Latency Comparison (20000 operations)
----------------------------------------------------------------------
[TCP Loopback] Duration: 0.8521s | Throughput: 46942.8 ops/sec
[Unix Socket]  Duration: 0.6124s | Throughput: 65316.7 ops/sec
[ANALYSIS] Unix socket is 39.1% faster than loopback due to bypassed networking layers.

----------------------------------------------------------------------
Phase 2: PHP-FPM Web Concurrency & Throughput Benchmark
----------------------------------------------------------------------
[*] Simulating load of 1000 requests with a concurrency limit of 20...
[✓] HTTP Concurrency Benchmark Complete!
    Throughput Rate:    215.42 req/sec
    Average Latency:    92.84 ms
    Failed Requests:    0
    Latency Distribution:
      p50 (Median):      88 ms
      p90:               112 ms
      p99 (Tail):        145 ms

----------------------------------------------------------------------
Phase 3: Sizing Audit & MariaDB Database Buffer Sizing
----------------------------------------------------------------------
[✓] No max_children exhaustion warnings detected in /var/log/php8.5-fpm.log.
 Active Workers:         189
 Avg RAM per Worker:     40 MB

 [MariaDB Sizing Verification]
  - Configured Buffer Pool Size:  1536 MB
  - Active DB Table/Index Size:   300 MB
  - Buffer Cache Occupancy:       19%
  - Cache Sizing Margin:          PASS (Healthy Memory headroom remains)
======================================================================
```
