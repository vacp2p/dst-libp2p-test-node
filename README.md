## libp2p GossipSub Test Nodes

This repository contains [nim-libp2p](https://github.com/vacp2p/nim-libp2p), [go-libp2p](https://github.com/libp2p/go-libp2p) and [rust-libp2p](https://github.com/libp2p/rust-libp2p) based implementations of GossipSub test nodes that can run in both [Kubernetes (K8s)](https://kubernetes.io/) and [Shadow simulator](https://github.com/shadow/shadow) environments.

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

```bash
git clone https://github.com/vacp2p/dst-libp2p-test-node.git
cd dst-libp2p-test-node

# Build Docker image
docker build -t nim-libp2p-test .
docker tag nim-libp2p-test user/refactored-test-node:vx.x

# Extract binary for Shadow
docker create --name temp nim-libp2p-test
docker cp temp:/node/main shadow/main
docker rm temp
```

#### Deployment

Please see [K8s deployment utilities](https://github.com/vacp2p/10ksim/tree/master/deployment-utilities/docker_utilities/nimlibp2p/publisher_headless) for K8s deployments. See [shadow directory](https://github.com/vacp2p/dst-libp2p-test-node/tree/master/shadow) for shadow simulator experiments.

