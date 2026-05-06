# nim-libp2p Test Node

A test node for benchmarking GossipSub message delivery latency with different QUIC/lsquic configurations.

## Problem Statement

nim-libp2p v1.16.0 with old lsquic (commit 6ae249c) exhibits **seconds-level delays** in GossipSub message delivery when using QUIC transport in multi-node networks. This is caused by suboptimal QUIC settings in the old lsquic version.

## Solution

Upgrading to **lsquic v0.3.0** resolves the latency issue. The key improvements in v0.3.0 include:
- Larger flow control windows
- Improved stream handling
- Better default settings for low-latency scenarios

## Recommendation

**Update nim-libp2p v1.16.0 to use `lsquic >= 0.3.0`** in its nimble dependencies. This ensures the fix is automatically applied.

```nimble
# In libp2p.nimble:
requires "lsquic >= 0.3.0"
```

## Test Scenarios

| Dockerfile | nim-libp2p | nim-lsquic | Expected Latency |
|------------|------------|--------|------------------|
| `Dockerfile_default` | v1.16.0 | 6ae249c (0.0.1) | **HIGH** (seconds) |
| `Dockerfile_libp2p_v1153` | v1.15.3 (latest release, but still uses nim-lsquic 0.0.1) | 6ae249c (0.0.1) | **HIGH** (seconds) |
| `Dockerfile_lsquic_030` | v1.16.0 | v0.3.0 | **LOW** (ms) |
| `Dockerfile_lsquic_030_no_pacing` | v1.16.0 | v0.3.0 + pacing=0 | **LOW** (ms) |
| `Dockerfile_lsquic_030_bbr` | v1.16.0 | v0.3.0 + BBR CC | **LOW** (ms) |

## Quick Start with Docker Compose

### Run a Test

```bash
# Terminal 1: Start the test network (20 nodes + publisher)
TEST=default docker compose up --build

# Or test with the fix:
TEST=lsquic_030 docker compose up --build
```

### Monitor Latency

```bash
# Terminal 2: Watch messages with latency > 10ms
docker compose logs -f | grep 'milliseconds:' | awk '$NF > 10'
```

### Available Scenarios

```bash
# Baseline - old lsquic (expect HIGH latency)
TEST=default docker compose up --build

# nim-libp2p v1.15.3 (expect HIGH latency)
TEST=libp2p_v1153 docker compose up --build

# lsquic v0.3.0 - THE FIX (expect LOW latency)
TEST=lsquic_030 docker compose up --build

# lsquic v0.3.0 with pacing disabled
TEST=lsquic_030_no_pacing docker compose up --build

# lsquic v0.3.0 with BBR congestion control
TEST=lsquic_030_bbr docker compose up --build
```

### Cleanup

```bash
docker compose down -v
```

## Kubernetes Deployment

### Build and Push Images

```bash
# Build all scenarios
for scenario in default libp2p_v1153 lsquic_030 lsquic_030_no_pacing lsquic_030_bbr; do
  docker build -f Dockerfile_${scenario} -t mamoutoudiarra/nim-libp2p-test:${scenario} .
  docker push mamoutoudiarra/nim-libp2p-test:${scenario}
done
```

### Deploy to Kubernetes

Edit `nimlibp2p.yaml` to select the image tag, then:

```bash
# Deploy the test network
kubectl apply -f nimlibp2p.yaml

# Check pods
kubectl get pods -n libp2p-lab

# View logs
kubectl logs -n libp2p-lab -l app=nim-quic -f | grep 'milliseconds:' | awk '$NF > 10'

# Deploy the publisher
kubectl apply -f publisher.yaml
```

### Switch Scenarios in Kubernetes

Edit the image tag in `nimlibp2p.yaml`:

```yaml
image: mamoutoudiarra/nim-libp2p-test:lsquic_030  # Change this tag
```

Available tags:
- `:default` - baseline (high latency)
- `:libp2p_v1153` - v1.15.3 (high latency)
- `:lsquic_030` - v0.3.0 fix (low latency)
- `:lsquic_030_no_pacing` - v0.3.0 + no pacing
- `:lsquic_030_bbr` - v0.3.0 + BBR

## Project Structure

```
nim-test-node/
├── docker-compose.yaml          # Docker Compose test suite
├── nimlibp2p.yaml               # Kubernetes StatefulSet
├── publisher.yaml               # Kubernetes publisher job
├── Dockerfile_default           # Baseline: v1.16.0 + old lsquic
├── Dockerfile_libp2p_v1153      # nim-libp2p v1.15.3
├── Dockerfile_lsquic_030        # v1.16.0 + lsquic v0.3.0 (the fix)
├── Dockerfile_lsquic_030_no_pacing  # v0.3.0 + pacing disabled
├── Dockerfile_lsquic_030_bbr    # v0.3.0 + BBR congestion control
├── nim-libp2p/                  # Submodule: vacp2p/nim-libp2p
├── nim-lsquic/                  # Submodule: vacp2p/nim-lsquic
├── main.nim                     # Test node implementation
├── env.nim                      # Environment configuration
└── test_node.nimble             # Nimble package file
```

## Submodules

This repo uses git submodules for `nim-libp2p` and `nim-lsquic`:

```bash
# Clone with submodules
git clone --recurse-submodules <repo-url>

# Or init submodules after clone
git submodule update --init --recursive
```

## Key Findings

1. **lsquic v0.3.0** resolves the high latency issue
2. The improvement comes from better QUIC settings (flow control windows, stream handling)
3. Both pacing enabled and disabled work well with v0.3.0
4. BBR congestion control also works well

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PEERS` | 20 | Expected number of peers in network |
| `CONNECTTO` | 10 | Number of peers to connect to |
| `MUXER` | quic | Multiplexer (quic/yamux) |
| `FRAGMENTS` | 1 | Message fragments |
| `SERVICE` | nimp2p-service | Service name for discovery |
| `MAXCONNECTIONS` | 128 | Maximum connections |
