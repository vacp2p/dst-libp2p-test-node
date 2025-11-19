# Rust-libP2P GossipSub Test Node

The [rust-libp2p](https://github.com/libp2p/rust-libp2p) based test node provides a flexible and extensible environment for GossipSub experiments. It supports yamux/quic transports, and follows the same features and architecture as in the the `nim-libp2p` and `go-libp2p` [test nodes](https://github.com/vacp2p/dst-libp2p-test-node).

## Features

- Configurable test node parameters
- Multi-transport support (Yamux, QUIC)
- Message fragmentation support
- HTTP-based message injection for dynamic test configuration
- Latency measurements for message propagation
- Prometheus metrics collection
- Kubernetes and shadow deployment

## Environment Variables

- `PEERS` — Number of peers in the network (default: `100`)
- `CONNECTTO` — Target number of peers to dial (default: `10`)
- `MUXER` — Stream multiplexer (default: `yamux`)
- `FRAGMENTS` — Number of message fragments (default: `1`)
- `SHADOWENV` — Whether running in shadow simulator (default: `false`)
- `SERVICE` — K8s service name for peer discovery (default: `nimp2p-service`) 


## Building

```bash
git clone https://github.com/vacp2p/dst-libp2p-test-node.git
cd dst-libp2p-test-node/rust-test-node

# Build Docker image
docker build -t rust-libp2p-test .
docker tag rust-libp2p-test user/rust-test-node:vx.x

# Extract binary for shadow simulator
docker create --name temp rust-libp2p-test
docker cp temp:/node/main ../shadow/main
docker rm temp
```

