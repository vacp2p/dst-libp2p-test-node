#!/bin/bash
set -e

# nim-lsquic benchmark runner
# Runs a matrix of benchmark scenarios via Docker Compose.
#
# Usage:
#   ./benchmarks/run.sh [--quick] [--mode MODE] [--scenario SCENARIO]
#
# Options:
#   --quick       Run minimal scenarios (LAN only, fewer runs)
#   --mode MODE   Run only one benchmark mode
#   --scenario SC Run only one network scenario
#   --no-build    Skip Docker image build
#   --help        Show this help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
RESULTS_DIR="$SCRIPT_DIR/results"
LOCK_DIR="$RESULTS_DIR/.run.lock"
WAIT_TIMEOUT=30
COMPOSE_ARGS=(-f "$COMPOSE_FILE")

acquire_lock() {
  local pid

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return
  fi

  if [ -f "$LOCK_DIR/pid" ]; then
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
      echo $$ > "$LOCK_DIR/pid"
      return
    fi
  fi

  echo "Another benchmark run is already active. Stop it before starting a new one."
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$LOCK_DIR"
  exit "$status"
}

QUICK=false
FILTER_MODE=""
FILTER_SCENARIO=""
NO_BUILD=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --quick) QUICK=true; shift ;;
    --mode) FILTER_MODE="$2"; shift 2 ;;
    --scenario) FILTER_SCENARIO="$2"; shift 2 ;;
    --no-build) NO_BUILD=true; shift ;;
    --help)
      head -12 "$0" | tail -10
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$RESULTS_DIR"
acquire_lock
trap cleanup EXIT INT TERM HUP

# Start from a clean project state in case a previous run was interrupted.
docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans >/dev/null 2>&1 || true

# -- Network scenarios --
# Format: NAME|LATENCY_MS|BANDWIDTH_MBIT|PACKET_LOSS_PCT|REORDER_PCT
if [ "$QUICK" = true ]; then
  SCENARIOS=(
    "lan|0|0|0|0"
  )
else
  SCENARIOS=(
    "lan|0|0|0|0"
    "wan|25|100|0|0"
    "constrained|50|10|0.1|0"
    "lossy|25|50|2|0"
    "mobile|75|5|1|0"
    "reorder|25|100|0|25"
  )
fi

# -- Benchmark modes --
# Format: MODE|RUNS|STREAMS|CONNECTIONS|UPLOAD_SIZE|DOWNLOAD_SIZE
if [ "$QUICK" = true ]; then
  BENCHMARKS=(
    "throughput|3|1|1|100000|1000000"
    "latency|20|1|1|0|0"
    "multistream|1|4|1|100000|1000000"
    "multiconn|1|1|3|100000|1000000"
    "stress|1|3|3|100000|1000000"
    "rampup|1|1|1|0|10000000"
  )
else
  BENCHMARKS=(
    "throughput|5|1|1|100000|10000000"
    "latency|100|1|1|0|0"
    "multistream|2|4|1|100000|10000000"
    "multiconn|2|1|4|100000|10000000"
    "stress|1|4|4|100000|10000000"
    "rampup|1|1|1|0|100000000"
  )
fi

# -- Build --
if [ "$NO_BUILD" = false ]; then
  echo "Building Docker image..."
  docker compose "${COMPOSE_ARGS[@]}" build --quiet bench-server 2>&1
  echo "Build complete."
fi

# -- Run matrix --
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY_FILE="$RESULTS_DIR/summary_${TIMESTAMP}.txt"
JSON_DIR="$RESULTS_DIR/json_${TIMESTAMP}"
mkdir -p "$JSON_DIR"

printf "\n%-15s %-14s %-6s %-6s %-15s %-15s %-12s %-12s %-12s\n" \
  "Scenario" "Mode" "Conns" "Strms" "Upload" "Download" "Lat p50" "Lat p95" "Duration" | tee "$SUMMARY_FILE"
printf "%s\n" "$(printf '=%.0s' {1..120})" | tee -a "$SUMMARY_FILE"

run_bench() {
  local scenario_str="$1"
  local bench_str="$2"

  IFS='|' read -r sc_name sc_lat sc_bw sc_loss sc_reorder <<< "$scenario_str"
  IFS='|' read -r bm_mode bm_runs bm_streams bm_conns bm_upload bm_download <<< "$bench_str"

  # Apply filters
  if [ -n "$FILTER_MODE" ] && [ "$bm_mode" != "$FILTER_MODE" ]; then
    return
  fi
  if [ -n "$FILTER_SCENARIO" ] && [ "$sc_name" != "$FILTER_SCENARIO" ]; then
    return
  fi

  local run_name="${sc_name}_${bm_mode}"
  echo -n "Running ${run_name}... "

  # tc netem only shapes egress (outbound) traffic. To cap bandwidth in both
  # directions we mirror the bandwidth limit on the server side so that the
  # server's outgoing download data is also shaped.
  # Latency/loss/reorder are kept client-only to avoid doubling the delay.
  local env_args=(
    "LATENCY_MS=$sc_lat"
    "BANDWIDTH_MBIT=$sc_bw"
    "PACKET_LOSS_PCT=$sc_loss"
    "REORDER_PCT=${sc_reorder:-0}"
    "SERVER_LATENCY_MS=0"
    "SERVER_BANDWIDTH_MBIT=$sc_bw"
    "SERVER_PACKET_LOSS_PCT=0"
    "SERVER_REORDER_PCT=0"
    "BENCH_MODE=$bm_mode"
    "BENCH_RUNS=$bm_runs"
    "BENCH_STREAMS=$bm_streams"
    "BENCH_CONNECTIONS=$bm_conns"
    "BENCH_UPLOAD_SIZE=$bm_upload"
    "BENCH_DOWNLOAD_SIZE=$bm_download"
  )

  # Make each scenario self-contained even if the previous one was interrupted.
  env "${env_args[@]}" docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans \
    >/dev/null 2>&1 || true

  # Bring up the server first and wait for the healthcheck to pass before
  # running the client. This removes the client/server startup race.
  if ! env "${env_args[@]}" docker compose "${COMPOSE_ARGS[@]}" up \
      -d \
      --wait \
      --wait-timeout "$WAIT_TIMEOUT" \
      bench-server >/dev/null 2>&1; then
    echo "FAILED (server startup)"
    printf "%-15s %-14s %-6s %-6s %-15s %-15s %-12s %-12s %-12s\n" \
      "$sc_name" "$bm_mode" "$bm_conns" "$bm_streams" "FAILED" "-" "-" "-" "-" \
      | tee -a "$SUMMARY_FILE"
    env "${env_args[@]}" docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans \
      >/dev/null 2>&1 || true
    return
  fi

  # Only attach to bench-client so the output contains bench_client logs only.
  local raw_output client_status output
  set +e
  raw_output=$(
    env "${env_args[@]}" docker compose "${COMPOSE_ARGS[@]}" up \
      --no-deps \
      --abort-on-container-exit \
      --exit-code-from bench-client \
      --no-color \
      --no-log-prefix \
      bench-client 2>/dev/null
  )
  client_status=$?
  set -e

  output=$(printf "%s\n" "$raw_output" | sed -n '/^{/,/^}/p' || true)

  env "${env_args[@]}" docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans \
    >/dev/null 2>&1 || true

  if [ -z "$output" ]; then
    if [ "$client_status" -ne 0 ]; then
      echo "FAILED (bench-client exit $client_status)"
    else
      echo "FAILED (no JSON output)"
    fi
    printf "%-15s %-14s %-6s %-6s %-15s %-15s %-12s %-12s %-12s\n" \
      "$sc_name" "$bm_mode" "$bm_conns" "$bm_streams" "FAILED" "-" "-" "-" "-" \
      | tee -a "$SUMMARY_FILE"
    return
  fi

  # Save raw JSON
  echo "$output" > "$JSON_DIR/${run_name}.json"

  # Parse key metrics with a simple approach
  local duration_ns upload_bps download_bps lat_p50 lat_p95
  duration_ns=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['duration_ns'])" 2>/dev/null || echo "0")

  # Extract throughput from first throughput stream
  local upload_str="-" download_str="-" lat_p50_str="-" lat_p95_str="-"

  python3 -c "
import sys, json

d = json.load(sys.stdin)
dur_ns = d['duration_ns']

# Aggregate bytes across all streams, then compute throughput as
# total_bytes / total_run_duration. This is correct for both sequential
# runs (gives average throughput) and parallel streams/conns (gives
# aggregate bandwidth).
total_up = 0
total_down = 0
latencies = []

for cr in d.get('connections_results', []):
    for sr in cr.get('streams', []):
        total_up += sr.get('upload_bytes', 0)
        total_down += sr.get('download_bytes', 0)
        latencies.extend(sr.get('latency_samples_ns', []))

# Format throughput
def fmt_bps(bytes_val, ns):
    if ns <= 0 or bytes_val <= 0:
        return '-'
    bps = bytes_val * 8 * 1e9 / ns
    if bps >= 1e9: return f'{bps/1e9:.2f} Gbit/s'
    if bps >= 1e6: return f'{bps/1e6:.2f} Mbit/s'
    if bps >= 1e3: return f'{bps/1e3:.2f} Kbit/s'
    return f'{bps:.0f} bit/s'

def fmt_dur(ns):
    if ns >= 1e9: return f'{ns/1e9:.3f}s'
    if ns >= 1e6: return f'{ns/1e6:.3f}ms'
    if ns >= 1e3: return f'{ns/1e3:.3f}us'
    return f'{ns}ns'

up_str = fmt_bps(total_up, dur_ns)
down_str = fmt_bps(total_down, dur_ns)

if latencies:
    latencies.sort()
    p50 = latencies[int(len(latencies) * 0.50)]
    p95 = latencies[min(int(len(latencies) * 0.95), len(latencies)-1)]
    lat_p50_str = fmt_dur(p50)
    lat_p95_str = fmt_dur(p95)
else:
    lat_p50_str = '-'
    lat_p95_str = '-'

# For rampup mode, show time-to-p90 in the latency columns
if d.get('mode') == 'rampup':
    for cr in d.get('connections_results', []):
        for sr in cr.get('streams', []):
            t90 = sr.get('time_to_p90_ns', 0)
            if t90 > 0:
                lat_p50_str = fmt_dur(t90)
                lat_p95_str = 'p90'

dur_str = fmt_dur(dur_ns)

print(f'{up_str}|{down_str}|{lat_p50_str}|{lat_p95_str}|{dur_str}')
" <<< "$output" 2>/dev/null | {
    IFS='|' read -r upload_str download_str lat_p50_str lat_p95_str dur_str
    echo "done"
    printf "%-15s %-14s %-6s %-6s %-15s %-15s %-12s %-12s %-12s\n" \
      "$sc_name" "$bm_mode" "$bm_conns" "$bm_streams" "$upload_str" "$download_str" \
      "$lat_p50_str" "$lat_p95_str" "$dur_str" \
      | tee -a "$SUMMARY_FILE"
  }

}

for scenario in "${SCENARIOS[@]}"; do
  for bench in "${BENCHMARKS[@]}"; do
    run_bench "$scenario" "$bench"
  done
done

echo ""
echo "Results saved to: $RESULTS_DIR/"
echo "  Summary: $SUMMARY_FILE"
echo "  JSON:    $JSON_DIR/"
