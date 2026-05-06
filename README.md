## libp2p GossipSub Test Nodes

This repository contains [nim-libp2p](https://github.com/vacp2p/nim-libp2p), [go-libp2p](https://github.com/libp2p/go-libp2p) and [rust-libp2p](https://github.com/libp2p/rust-libp2p) based implementations of GossipSub test nodes that can run in both [Kubernetes (K8s)](https://kubernetes.io/) and [Shadow simulator](https://github.com/shadow/shadow) environments.

## Quick Start

### Clone the Repository

```bash
git clone --recurse-submodules https://github.com/vacp2p/dst-libp2p-test-node.git
cd dst-libp2p-test-node
git checkout mamoutou/disable-lsquic-pacing
git submodule update --init --recursive
```

### Overview

These test nodes are designed for performance testing and evaluation of libp2p's GossipSub protocol under various network conditions. The implementations support:

- Configurable test node parameters
- Kubernetes and shadow deployment
- Multi-transport support (Mplex, Yamux, QUIC)
- Mix protocol support (for nim-libp2p)
- Prometheus metrics collection
- HTTP-based message injection for dynamic test configuration

Node/test-specific details are available in corresponding directories.


### How It Works

Peers use random (ID-based) peer selection in the shadow simulator, and a DNS-based peer discovery service in K8s to make target number of connections. After required connections are made, each peer exposes an HTTP endpoint for receiving publish commands from a [remote message injector](https://github.com/vacp2p/10ksim/blob/master/deployment-utilities/docker_utilities/nimlibp2p/publisher_headless/README.md).

Every publisher embeds a timestamp before publishing messages. If fragmentation is required, the publisher breaks messages into desired fragments and embeds fragment numbers. The receiver accumulates fragments and logs the elapsed time. 

All peers expose Prometheus metrics for detailed insights.


### nim-libp2p Test Node

nim-libp2p test node supports mplex, yamux, and quic transports. It also supports mix protocol for improved anonymity. Use the `MOUNTSMIX` environment variable to mount mix protocol on any test node. Mix nodes also need to know the available number of mix nodes `NUMMIX`, and need access to their configuration settings using `FILEPATH`.   

#### Environment Variables

- `PEERS` — Number of peers in the network (default: `100`)
- `CONNECTTO` — Target number of peers to dial (default: `10`)
- `MUXER` — Stream multiplexer: supports QUIC, yamux and mplex (default: `yamux`)
- `FRAGMENTS` — Number of message fragments (default: `1`)
- `SHADOWENV` — Whether running in shadow simulator  (default: `false`)
- `SELFTRIGGER` — Self trigger in GossipSub parameters (default: `true`)
- `SERVICE` — K8s service name for peer discovery (default: `nimp2p-service`) 
- `MAXCONNECTIONS` — Maximum number of peers to connect with (default: `250`)
- `MOUNTSMIX` — Running as a mix node (default: `false`)
- `USESMIX` — Participate in mix network (default: `false`)
- `NUMMIX` — Number of mix network peers (default: `0`)
- `MIXD` — Number of mix tunnels to traverse (default: `4`)
- `FILEPATH` — Path of mix node configurations (default: `./`)


#### Building

**LSQUIC Performance Test Scenarios:**

| Dockerfile | nim-libp2p | nim-lsquic | Expected Latency |
|------------|------------|------------|------------------|
| `Dockerfile_default` | v1.16.0 | 6ae249c (0.0.1) | **HIGH** (seconds) |
| `Dockerfile_libp2p_v1153` | v1.15.3 | 6ae249c (0.0.1) | **HIGH** (seconds) |
| `Dockerfile_lsquic_030` | v1.16.0 | v0.3.0 | **LOW** (ms) ✓ |
| `Dockerfile_lsquic_030_no_pacing` | v1.16.0 | v0.3.0 + pacing=0 | **LOW** (ms) |
| `Dockerfile_lsquic_030_bbr` | v1.16.0 | v0.3.0 + BBR CC | **LOW** (ms) |

> **Recommendation:** Update nim-libp2p v1.16.0 to use `lsquic >= 0.3.0` in its nimble dependencies to fix the high latency issue.

```bash
cd nim-test-node

# Build a specific scenario
TEST=lsquic_030 docker compose up --build

# Or build manually
docker build -f ../nim-test-node/Dockerfile_lsquic_030 -t nim-libp2p-test:lsquic_030 .
```

#### Deployment

##### Docker Compose

Run a test network (20 nodes + publisher) using Docker Compose:

```bash
cd nim-test-node

# Terminal 1: Start the test network
TEST=lsquic_030 docker compose up --build

# Terminal 2: Monitor latency (messages > 10ms)
docker compose logs -f | grep 'milliseconds:' | awk '$NF > 10'
```

**Available test scenarios:**

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

# Cleanup
docker compose down -v
```

##### Kubernetes

Deploy a 100-node GossipSub network on Kubernetes using the manifests:

- `nimlibp2p.yaml` : Namespace, headless Service, and StatefulSet
- `publisher.yaml` : Message injection pod

**Available image tags:**
- `mamoutoudiarra/nim-libp2p-test:default` - v1.16.0 + old lsquic (HIGH latency)
- `mamoutoudiarra/nim-libp2p-test:libp2p_v1153` - v1.15.3 + old lsquic (HIGH latency)
- `mamoutoudiarra/nim-libp2p-test:lsquic_030` - v1.16.0 + lsquic v0.3.0 (LOW latency) ✓
- `mamoutoudiarra/nim-libp2p-test:lsquic_030_no_pacing` - v0.3.0 + pacing disabled
- `mamoutoudiarra/nim-libp2p-test:lsquic_030_bbr` - v0.3.0 + BBR CC

```bash
cd nim-test-node

# Build and push images
for scenario in default libp2p_v1153 lsquic_030 lsquic_030_no_pacing lsquic_030_bbr; do
  docker build -f Dockerfile_${scenario} -t mamoutoudiarra/nim-libp2p-test:${scenario} .
  docker push mamoutoudiarra/nim-libp2p-test:${scenario}
done

# Deploy namespace, service, and statefulset
kubectl apply -f nimlibp2p.yaml

# Wait for all pods to be ready (~2 minutes)
kubectl wait --for=condition=ready pod -l app=nim-quic -n libp2p-lab --timeout=180s

# Deploy publisher once all nodes are running
kubectl apply -f publisher.yaml

# Monitor latency
kubectl logs -f -n libp2p-lab -l app=nim-quic | grep 'milliseconds:' | awk '$NF > 10'

# Delete deployment
kubectl delete -f publisher.yaml
kubectl delete -f nimlibp2p.yaml
```

To switch scenarios, edit the image tag in `nimlibp2p.yaml`:
```yaml
image: mamoutoudiarra/nim-libp2p-test:lsquic_030  # Change this tag
```

##### Shadow Simulator

See [shadow directory](https://github.com/vacp2p/dst-libp2p-test-node/tree/master/shadow) for Shadow simulator experiments.

For additional K8s deployment utilities, see [10ksim deployment utilities](https://github.com/vacp2p/10ksim/tree/master/deployment-utilities/docker_utilities/nimlibp2p/publisher_headless).
