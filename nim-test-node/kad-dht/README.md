## Compile

Can be compiled locally with:
`-d:chronicles_colors=None --threads:on --mm:refc -d:metrics -d:libp2p_network_protocols_metrics -d:release -d:chronicles_log_level:NOTICE`

Useful debug levels: `NOTICE`, `INFO`, `DEBUG`
If you want to test with a local nim-libp2p version with local changes, it can be done with:

`-d:chronicles_colors=None --threads:on --mm:refc -d:metrics -d:libp2p_network_protocols_metrics -d:release -d:chronicles_log_level:NOTICE --path:/your/path/nim-libp2p`

## How to run

It expects the following ENV variables:

- PORT: Default `5000`
- MUXER: Default `yamux`.
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
