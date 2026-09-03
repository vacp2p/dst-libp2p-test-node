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


### Tags

To maintain reproducible scenarios, tags (and public docker images) should be created and documented in READMES.
Tag structure should work as follows:
```
<VERSION>-<IMPLEMENTATION>-<FOLDER>
```
For example, once we have everything ready for a new nim regression node version, we create the following tag:
```
v2.0.0-nim-regression
```
