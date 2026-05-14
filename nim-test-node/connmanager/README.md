# Connection Manager Test Node

Test node for evaluating nim-libp2p's connection manager introduced in [nim-libp2p#2284](https://github.com/vacp2p/nim-libp2p/pull/2284). Supports two roles in a hub-and-spoke topology: a hub with configurable watermark trimming, and peers with configurable connection strategies.

The nim-libp2p version pinned in `test_node.nimble` to [`dst/connmanager-logging`](https://github.com/vacp2p/nim-libp2p/tree/dst/connmanager-logging) (debug-level logging for connection manager events).

## Compile

```
nimble c \
  -d:chronicles_colors=None --threads:on --mm:refc \
  -d:metrics -d:libp2p_network_protocols_metrics -d:release \
  main.nim
```

To build with Docker:
```
docker buildx build --platform linux/amd64 -t radiken/dst-test-node-connmanager:latest --push .
```

## Environment variables

### Shared

| Variable | Default | Description |
|---|---|---|
| `PORT` | `5000` | Listening port |
| `NODE_ROLE` | `RoleHub` | `RoleHub` or `RolePeer` |

### Hub (`RoleHub`)

| Variable | Default | Description |
|---|---|---|
| `WATERMARK_LOW` | `10` | Low watermark threshold |
| `WATERMARK_HIGH` | `20` | High watermark threshold |
| `WATERMARK_GRACE_PERIOD_S` | `0` | Grace period for new connections (seconds) |
| `WATERMARK_SILENCE_PERIOD_S` | `2` | Minimum interval between trim cycles (seconds) |
| `MAX_CONNECTIONS` | `0` | Hard connection cap (0 = no cap) |
| `PROTECTED_PEERS` | | Comma-separated peer IDs to protect from trimming |
| `OUTBOUND_PEERS` | | Comma-separated addresses the hub dials proactively |
| `NUM_HUBS` | `1` | Total hub replicas; >1 enables hub-to-hub dialing |
| `HUB_NAMESPACE` | `nimlibp2p` | k8s namespace for hub-to-hub DNS resolution |

### Peer (`RolePeer`)

| Variable | Default | Description |
|---|---|---|
| `HUB_ADDRS` | | Comma-separated hub addresses (multi-hub) |
| `HUB_ADDR` | `hub:5000` | Single hub address (fallback if `HUB_ADDRS` not set) |
| `DIAL_OUT` | `true` | If `true`, peer dials hub; if `false`, peer listens |
| `RECONNECT` | `none` | `none`, `aggressive`, or `before_grace` |
| `RECONNECT_INTERVAL_S` | `55` | Reconnect cycle interval for `before_grace` mode |
| `PRIVATE_KEY` | | Hex-encoded protobuf secp256k1 private key |
| `PRIVATE_KEYS` | | Comma-separated keys; pod picks by StatefulSet ordinal |
