## How to run

It expects the following ENV variables:

- PORT: Default `5000`
- MUXER: Default `yamux`. Options [`mplex`, `yamux`, `quic`]
- DISCOVERY: Default `kad-dht`. Options [`kad-dht`, `extended`]
- NODE_ROLE: Default `RoleBootstrap`. Options [`RoleBootstrap`, `RoleNormal`, `RoleProbe`]

- SERVICE: Kubernetes headless service for connecting to bootstrap nodes. ie: `kad-service:5000`
  - Can also be used as local node. ie: `127.0.0.1:5000`



Compile and run `main.nim`. Example:

### 1. For running bootstrap

Env variables:
```bash
NODE_ROLE=RoleBootstrap PORT=5001 main
```

### 2. For running nodes

Env variables for node 1, if you want to use more nodes, remember to increase `PORT` on the other executions:
```bash
NODE_ROLE=RoleNormal \
PORT=5002 \
SERVICE=127.0.0.1:5001 main
```
