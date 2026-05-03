# nim-lsquic Benchmark Harness

Docker-based harness for measuring bandwidth and latency of nim-lsquic under
various network conditions. Runs a QUIC server and client in separate containers
connected via a Docker bridge network, with configurable latency, bandwidth
limits, packet loss, and packet reordering via `tc netem`.

## Defaults

| Parameter | CLI default | Docker Compose default |
|-----------|-------------|----------------------|
| Mode | `throughput` | `throughput` |
| Port | `14555` | `14555` |
| Upload size | 100 KB (`100000`) | 100 KB (`100000`) |
| Download size | 100 MB (`100000000`) | 10 MB (`10000000`) |
| Chunk size | 64 KB (`65536`) | 64 KB (`65536`) |
| Runs | `10` | `5` |
| Streams/conn | `4` | `4` |
| Connections | `4` | `4` |

> The Docker Compose defaults use a smaller download size and fewer runs to keep
> container-based benchmarks practical. Adjust via environment variables as needed.

## Benchmark Modes

| Mode | Connections | Streams/conn | What it measures |
|------|-------------|-------------|------------------|
| `throughput` | 1 | 1 | Baseline upload/download bandwidth |
| `latency` | 1 | 1 | Baseline RTT (ping/pong echo) |
| `multistream` | 1 | K (default: 4) | Stream contention within a single connection |
| `multiconn` | N (default: 4) | 1 | Connection contention across separate QUIC connections |
| `stress` | N (default: 4) | K (default: 4) | Combined connection + stream contention |
| `rampup` | 1 | 1 | Congestion control ramp-up: throughput over time from cold start |

### `throughput`

Opens a single connection with a single stream. The client uploads a configurable
amount of data, then the server sends back a configurable download payload. This
gives you the baseline maximum bandwidth nim-lsquic can push through one stream
with no contention. Use this to establish an upper bound before testing with
concurrent load.

### `latency`

Opens a single connection with a single stream dedicated to ping/pong. The client
sends a small 64-byte payload, the server echoes it back, and the client measures
the round-trip time. Repeats for the configured number of runs. This gives you
the baseline RTT with no competing traffic — the floor against which you compare
the other modes.

### `multistream`

Opens a single connection with K streams. K-1 streams do bulk throughput
transfers (upload + download) while 1 stream acts as a **latency probe** running
the same ping/pong as the `latency` mode. All streams share the same QUIC
connection, meaning they share one congestion window, one flow control context,
and one `engine_process` call. This answers the question: *does bulk traffic on
other streams within the same connection degrade latency?* If the latency probe
p50/p95 increases significantly compared to the `latency` baseline, it points to
stream-level contention inside lsquic (stream scheduling, flow control
head-of-line blocking, or engine processing overhead).

### `multiconn`

Opens N separate QUIC connections, each with a single stream. N-1 connections do
bulk throughput transfers while 1 connection runs the latency probe. Each
connection gets its own congestion state, but on the server side they still share
the same UDP socket and the same lsquic engine (one `engine_process` call handles
all connections). This answers: *does load from other connections degrade latency
on a separate connection?* Degradation here points to server-side engine
contention or UDP socket bottlenecks rather than stream-level issues.

### `stress`

The most realistic scenario. Opens N connections with K streams each. On every
connection, K-1 streams do bulk transfers and 1 stream runs the latency probe.
This combines the contention from both `multistream` and `multiconn` — stream
scheduling pressure within each connection, plus engine-level pressure across
connections. Compare the latency probe results against the `latency`, `multistream`,
and `multiconn` baselines to isolate where degradation comes from.

### `rampup`

Opens a single connection with a single stream and starts a large download.
Instead of reporting a single aggregate throughput number, it samples throughput
in 50ms time windows and plots how bandwidth evolves from the start. This shows
CUBIC slow-start behavior: how quickly the congestion window grows, how long it
takes to reach steady state, and whether the connection fully utilizes the
available bandwidth.

The key metric is **time to 90% of peak throughput** — the point where
slow-start has essentially finished. Under high-latency or lossy conditions, this
ramp-up time grows significantly because CUBIC's window growth depends on RTT.
Compare across network scenarios to see how network conditions affect convergence
time.

Example output (100MB download over WAN with 25ms latency, 100 Mbit cap):

```
Stream #1 [ramp-up] (20 windows, 50ms each):
  Time to 90% peak: 150.000ms
  Peak throughput:  83.48 Mbit/s
  Timeline:
       50ms |    12.3 Mbit/s | ######
      100ms |    68.7 Mbit/s | #################################
      150ms |    83.5 Mbit/s | ########################################
      200ms |    82.9 Mbit/s | #######################################
      ...
```

## Network Scenarios

The matrix runner (`run.sh`) tests across these predefined network conditions
(all 6 used in full mode, only `lan` in `--quick` mode):

| Scenario | Latency | Bandwidth | Packet Loss | Reorder |
|----------|---------|-----------|-------------|---------|
| `lan` | 0ms | unlimited | 0% | 0% |
| `wan` | 25ms | 100 Mbit | 0% | 0% |
| `constrained` | 50ms | 10 Mbit | 0.1% | 0% |
| `lossy` | 25ms | 50 Mbit | 2% | 0% |
| `mobile` | 75ms | 5 Mbit | 1% | 0% |
| `reorder` | 25ms | 100 Mbit | 0% | 25% |

### `run.sh` Matrix Defaults

**Full mode** (`./benchmarks/run.sh`):

| Mode | Runs | Streams | Connections | Upload | Download |
|------|------|---------|-------------|--------|----------|
| `throughput` | 5 | 1 | 1 | 100 KB | 10 MB |
| `latency` | 100 | 1 | 1 | — | — |
| `multistream` | 2 | 4 | 1 | 100 KB | 10 MB |
| `multiconn` | 2 | 1 | 4 | 100 KB | 10 MB |
| `stress` | 1 | 4 | 4 | 100 KB | 10 MB |
| `rampup` | 1 | 1 | 1 | — | 100 MB |

**Quick mode** (`./benchmarks/run.sh --quick`) — LAN scenario only:

| Mode | Runs | Streams | Connections | Upload | Download |
|------|------|---------|-------------|--------|----------|
| `throughput` | 3 | 1 | 1 | 100 KB | 1 MB |
| `latency` | 20 | 1 | 1 | — | — |
| `multistream` | 1 | 4 | 1 | 100 KB | 1 MB |
| `multiconn` | 1 | 1 | 3 | 100 KB | 1 MB |
| `stress` | 1 | 3 | 3 | 100 KB | 1 MB |
| `rampup` | 1 | 1 | 1 | — | 10 MB |

## Prerequisites

- Docker (with Compose V2)
- `NET_ADMIN` capability (needed for `tc netem` inside containers)

## Quick Start

```bash
# Run the full matrix (6 scenarios x 6 modes = 36 benchmarks)
./benchmarks/run.sh

# Quick mode: LAN only, smaller payloads, fewer runs
./benchmarks/run.sh --quick

# Single scenario or mode
./benchmarks/run.sh --scenario wan --mode latency

# Skip Docker image rebuild (if already built)
./benchmarks/run.sh --quick --no-build
```

## Direct Docker Compose Usage

For more control, run Docker Compose directly with environment variables:

```bash
# Throughput test with 50ms latency and 10Mbit bandwidth cap
BENCH_MODE=throughput BENCH_RUNS=5 \
BENCH_UPLOAD_SIZE=100000 BENCH_DOWNLOAD_SIZE=10000000 \
LATENCY_MS=50 BANDWIDTH_MBIT=10 \
  docker compose -f benchmarks/docker-compose.yml up \
    --abort-on-container-exit --exit-code-from bench-client

# Stress test: 8 connections x 8 streams, lossy network
BENCH_MODE=stress BENCH_CONNECTIONS=8 BENCH_STREAMS=8 \
LATENCY_MS=25 PACKET_LOSS_PCT=2 BANDWIDTH_MBIT=50 \
  docker compose -f benchmarks/docker-compose.yml up \
    --abort-on-container-exit --exit-code-from bench-client

# Clean up after
docker compose -f benchmarks/docker-compose.yml down --remove-orphans
```

### Environment Variables

**Benchmark parameters:**

| Variable | Default | Description |
|----------|---------|-------------|
| `BENCH_MODE` | `throughput` | Benchmark mode |
| `BENCH_RUNS` | `5` | Number of iterations |
| `BENCH_CONNECTIONS` | `4` | Number of QUIC connections (multiconn/stress) |
| `BENCH_STREAMS` | `4` | Streams per connection (multistream/stress) |
| `BENCH_UPLOAD_SIZE` | `100000` | Bytes to upload per stream (100 KB) |
| `BENCH_DOWNLOAD_SIZE` | `10000000` | Bytes to download per stream (10 MB) |
| `BENCH_CHUNK_SIZE` | `65536` | I/O chunk size (64 KB) |

**Network shaping (applied on client side):**

| Variable | Default | Description |
|----------|---------|-------------|
| `LATENCY_MS` | `0` | One-way delay in milliseconds |
| `BANDWIDTH_MBIT` | `0` | Bandwidth limit in Mbit/s (0 = unlimited) |
| `PACKET_LOSS_PCT` | `0` | Packet loss percentage |
| `JITTER_MS` | `0` | Delay jitter in milliseconds |
| `REORDER_PCT` | `0` | Packet reorder percentage (requires `LATENCY_MS` > 0) |

## Running Locally (Without Docker)

You can compile and run the benchmarks directly for loopback testing:

```bash
# Compile
nim c --threads:on -d:release --out:benchmarks/bench_server benchmarks/bench_server.nim
nim c --threads:on -d:release --out:benchmarks/bench_client benchmarks/bench_client.nim

# Run server in background
./benchmarks/bench_server --port 14555 &

# Run client
./benchmarks/bench_client --mode stress --server 127.0.0.1 --port 14555 \
  --connections 4 --streams 4 --runs 3 --json

# Kill server when done
kill %1
```

### Server CLI Options

```
--listen, -l       Listen address (default: 0.0.0.0)
--port, -p         Port (default: 14555)
```

### Client CLI Options

```
--mode, -m         Benchmark mode (default: throughput)
                   Options: throughput|latency|multistream|multiconn|stress|rampup
--server, -s       Server address (default: 127.0.0.1)
--port, -p         Server port (default: 14555)
--upload-size      Bytes to upload per stream (default: 100000 = 100 KB)
--download-size    Bytes to download per stream (default: 100000000 = 100 MB)
--chunk-size       I/O chunk size (default: 65536 = 64 KB)
--runs, -r         Number of iterations (default: 10)
--streams, -k      Streams per connection (default: 4)
--connections, -n  Number of connections (default: 4)
--json             Output results as JSON (default: human-readable)
```

## Output

### Sample Run

Full matrix run (`./benchmarks/run.sh`) across all 6 scenarios and 6 modes:

```
Scenario        Mode           Conns  Strms  Upload          Download        Lat p50      Lat p95      Duration
========================================================================================================================
lan             throughput     1      1      10.99 Mbit/s    1.10 Gbit/s     -            -            363.907ms
lan             latency        1      1      -               -               57.966us     173.932us    7.530ms
lan             multistream    1      4      11.15 Mbit/s    1.11 Gbit/s     1.277ms      10.798ms     430.670ms
lan             multiconn      4      1      11.82 Mbit/s    1.18 Gbit/s     293.599us    15.731ms     406.153ms
lan             stress         4      4      13.90 Mbit/s    1.39 Gbit/s     8.207ms      37.689ms     690.415ms
lan             rampup         1      1      -               1.09 Gbit/s     150.000ms    p90          736.432ms
wan             throughput     1      1      900.16 Kbit/s   90.02 Mbit/s    -            -            4.444s
wan             latency        1      1      -               -               25.660ms     25.761ms     2.565s
wan             multistream    1      4      703.95 Kbit/s   70.39 Mbit/s    25.697ms     220.947ms    6.819s
wan             multiconn      4      1      750.57 Kbit/s   75.06 Mbit/s    36.330ms     36.402ms     6.395s
wan             stress         4      4      573.97 Kbit/s   57.40 Mbit/s    25.731ms     1.029s       16.726s
wan             rampup         1      1      -               94.22 Mbit/s    150.000ms    p90          8.491s
constrained     throughput     1      1      92.32 Kbit/s    9.23 Mbit/s     -            -            43.327s
constrained     latency        1      1      -               -               50.792ms     50.977ms     5.082s
constrained     multistream    1      4      94.25 Kbit/s    9.43 Mbit/s     94.594ms     163.685ms    50.928s
constrained     multiconn      4      1      93.94 Kbit/s    9.39 Mbit/s     96.019ms     100.841ms    51.096s
constrained     stress         4      4      92.25 Kbit/s    9.22 Mbit/s     50.928ms     122.342ms    104.068s
constrained     rampup         1      1      -               9.49 Mbit/s     900.000ms    p90          84.324s
lossy           throughput     1      1      405.86 Kbit/s   40.59 Mbit/s    -            -            9.856s
lossy           latency        1      1      -               -               25.695ms     25.902ms     2.571s
lossy           multistream    1      4      346.40 Kbit/s   34.64 Mbit/s    25.724ms     824.939ms    13.857s
lossy           multiconn      4      1      339.58 Kbit/s   33.96 Mbit/s    47.512ms     47.747ms     14.135s
lossy           stress         4      4      320.42 Kbit/s   32.04 Mbit/s    25.762ms     995.620ms    29.961s
lossy           rampup         1      1      -               41.33 Mbit/s    150.000ms    p90          19.356s
mobile          throughput     1      1      45.32 Kbit/s    4.53 Mbit/s     -            -            88.260s
mobile          latency        1      1      -               -               75.919ms     76.187ms     7.902s
mobile          multistream    1      4      46.90 Kbit/s    4.69 Mbit/s     123.369ms    614.949ms    102.349s
mobile          multiconn      4      1      46.61 Kbit/s    4.66 Mbit/s     119.147ms    351.425ms    102.988s
mobile          stress         4      4      46.42 Kbit/s    4.64 Mbit/s     121.724ms    453.206ms    206.803s
mobile          rampup         1      1      -               4.74 Mbit/s     3.350s       p90          168.757s
reorder         throughput     1      1      672.33 Kbit/s   67.23 Mbit/s    -            -            5.949s
reorder         latency        1      1      -               -               25.690ms     25.896ms     2.417s
reorder         multistream    1      4      636.49 Kbit/s   63.65 Mbit/s    25.677ms     441.939ms    7.541s
reorder         multiconn      4      1      664.28 Kbit/s   66.43 Mbit/s    36.302ms     36.407ms     7.226s
reorder         stress         4      4      746.94 Kbit/s   74.69 Mbit/s    25.704ms     934.372ms    12.852s
reorder         rampup         1      1      -               90.96 Mbit/s    100.000ms    p90          8.795s
```

#### Reading the results

**Columns:**

- **Scenario** — network condition profile applied via `tc netem` (see
  [Network Scenarios](#network-scenarios) above for the exact latency, bandwidth,
  and loss values each name maps to)
- **Mode** — benchmark mode that was run
- **Conns** — number of QUIC connections used
- **Strms** — number of streams per connection
- **Upload** — aggregate upload throughput across all streams, computed as total
  bytes uploaded divided by total wall-clock duration. Shows `-` for latency-only
  modes where no bulk data is transferred. Note: in throughput mode the upload is
  small relative to the download, so this number reflects the fraction of time
  spent uploading rather than burst upload speed.
- **Download** — same as Upload but for the download direction
- **Lat p50** — median (50th percentile) round-trip time from the latency probe
  stream. This is the RTT of a small ping/pong echo measured alongside any bulk
  transfers. Shows `-` for pure throughput mode which has no latency probe.
  For `rampup` mode, this column shows the **time to 90% of peak throughput**
  instead (labeled `p90` in the Lat p95 column).
- **Lat p95** — 95th percentile RTT. Useful for spotting tail latency spikes
  caused by contention or packet loss. Shows `p90` for `rampup` mode to indicate
  the Lat p50 column contains the time-to-90%-peak metric.
- **Duration** — total wall-clock time for the entire benchmark run (all
  iterations, all streams)

#### Analysis by scenario

**LAN** (no shaping) — establishes the upper bound. Single-stream download reaches
1.10 Gbit/s on the Docker bridge. With parallel streams and connections, aggregate
throughput climbs to 1.1-1.4 Gbit/s as multiplexing improves pipeline utilization.
Latency starts at 58us but grows to 8.2ms p50 / 37.7ms p95 under stress, showing
the cost of engine processing contention when handling 16 concurrent streams across
4 connections.

**WAN** (25ms, 100 Mbit) — throughput reaches 90 Mbit/s, below the 100 Mbit cap
because CUBIC needs multiple RTTs to grow the congestion window, and each of the 5
sequential runs starts cold. Latency baseline is 25.7ms, matching the netem delay
exactly. Under multiconn the probe latency rises to 36ms (+11ms), pointing to
engine-level contention across connections. Stress p95 hits 1.03s from head-of-line
blocking cascades across 16 concurrent streams. Rampup takes 150ms (6 RTTs) to
reach 90% of peak.

**Constrained** (50ms, 10 Mbit, 0.1% loss) — all modes saturate at ~9.2 Mbit/s,
confirming the 10 Mbit link is the bottleneck rather than the engine. Contention
modes show nearly identical throughput because there simply isn't more bandwidth
to fight over. The main effect of contention is on latency: multistream p95 reaches
164ms and stress p95 hits 122ms. Rampup takes 900ms (18 RTTs at 50ms) to reach
steady state, consistent with CUBIC slow-start behavior.

**Lossy** (25ms, 50 Mbit, 2% loss) — the most punishing scenario for throughput.
Single-stream reaches only 40.6 Mbit/s (81% of cap) because 2% loss causes frequent
congestion window reductions. Baseline latency p50 is 25.7ms, matching the netem
delay, with p95 at 25.9ms. Stress p95 reaches 996ms as loss and congestion combine
into retransmission cascades across 16 concurrent streams.

**Mobile** (75ms, 5 Mbit, 1% loss) — throughput settles at 4.5 Mbit/s (90% of
cap). The tight bandwidth means contention modes show nearly identical throughput
(~4.6 Mbit/s) since the link is fully saturated regardless. The contention effect
shows up in latency instead: multistream p95 reaches 615ms from within-connection
scheduling pressure under the narrow pipe. Rampup takes 3.35s to converge — longer
than expected from RTT alone, likely due to a loss event during slow-start forcing
a window reduction on this narrow, lossy link.

**Reorder** (25ms, 100 Mbit, 25% reorder) — throughput drops to 67.2 Mbit/s, 25%
lower than WAN (90 Mbit/s) despite the same bandwidth cap. Reordered packets
trigger duplicate ACKs that CUBIC interprets as loss, shrinking the congestion
window unnecessarily. This is a known weakness of loss-based congestion control.
However, reordering is less damaging than actual loss: 25% reorder yields 67.2
Mbit/s while 2% real loss (lossy scenario) yields only 40.6 Mbit/s, because
reordered packets eventually arrive and don't require retransmission.

#### Key takeaways

- **Bandwidth caps are enforced bidirectionally** — download throughput stays below
  the configured cap in all scenarios (shaping is applied on both client and server
  egress via `tc netem`).
- **Latency baselines match netem delays exactly** — 25.7ms for WAN/lossy/reorder
  (25ms configured), 50.8ms for constrained (50ms), 75.9ms for mobile (75ms).
- **Contention degrades latency more than throughput** — under constrained/mobile
  scenarios the link is fully saturated regardless of mode, but p95 latency grows
  2-6x from baseline under stress.
- **Packet loss is more damaging than reordering** — 2% loss (lossy) reduces
  throughput to 81% of cap and drives stress p95 to 996ms, while 25% reorder
  reduces throughput to only 67% and stress p95 to 934ms. Lost packets require
  actual retransmission and RTO backoff; reordered packets just trigger spurious
  duplicate ACKs.
- **CUBIC ramp-up scales with RTT** — time-to-90% grows from 150ms (LAN/WAN)
  to 900ms (50ms RTT) to 3.35s (75ms RTT + 1% loss), with loss events during
  slow-start significantly extending convergence on narrow, lossy links.

### Human-Readable Output

Without `--json`, the client prints a detailed breakdown:

```
=== Benchmark Results ===
Mode: stress
Connections: 3, Streams/conn: 3
Total duration: 11.079ms

  Connection #1:
    Stream #1 [throughput]:
      Upload:   10000 bytes -> 41.39 Mbit/s
      Download: 50000 bytes -> 206.96 Mbit/s
      Duration: 1.933ms
    Stream #2 [throughput]:
      Upload:   10000 bytes -> 19.48 Mbit/s
      Download: 50000 bytes -> 97.38 Mbit/s
      Duration: 4.108ms
    Stream #3 [latency] (50 samples):
      Mean:  213.898us
      p50:   90.164us
      p95:   456.471us
      p99:   801.782us
      Min:   51.400us
      Max:   3.967ms
  Connection #2:
    ...
```

### JSON Output

With `--json`, the client outputs machine-readable JSON with per-stream latency
samples (in nanoseconds) for further analysis:

```json
{
  "mode": "latency",
  "connections": 1,
  "streams_per_conn": 1,
  "duration_ns": 253988269,
  "connections_results": [
    {
      "streams": [
        {
          "upload_bytes": 0,
          "download_bytes": 0,
          "duration_ns": 253906378,
          "latency_samples_ns": [25814400, 25296524, 25294871, ...]
        }
      ],
      "duration_ns": 253988269
    }
  ]
}
```

## How It Works

1. **Server** listens for QUIC connections and handles two stream protocols:
   - **Throughput** (type `0x01`): reads upload data, sends back requested download size
   - **Latency** (type `0x02`): echoes length-prefixed payloads back immediately

2. **Client** opens connections/streams based on the selected mode. In multi-stream
   and multi-connection modes, it runs bulk transfers alongside a latency probe
   to measure contention effects.

3. **Network shaping** is applied via `tc netem` in the Docker entrypoint (requires
   `NET_ADMIN` capability). Since `tc qdisc` only shapes egress (outbound) traffic,
   bandwidth limits are applied on **both** the client and server sides so that
   uploads and downloads are both capped. Latency, packet loss, and reordering are
   applied on the client side only to avoid doubling the delay.

4. **Results** are collected as JSON per run and aggregated into a summary table
   by `run.sh`.
