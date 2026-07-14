## Service Discovery Test Node

This folder contains a standalone node to exercise `libp2p/protocols/service_discovery.nim`
in local setups or Kubernetes.

## Compile

From this folder:

```bash
nim c \
  -d:chronicles_colors=None \
  --threads:on \
  --mm:refc \
  -d:metrics \
  -d:libp2p_network_protocols_metrics \
  -d:release \
  -d:chronicles_log_level:NOTICE \
  main
```

If you need local `nim-libp2p` changes, do `nimble setup -l` and modify `nimble.paths` pointing to your local repo root.

## Node flow

On startup the node loads its configuration from environment variables, builds a libp2p switch, and creates a 
`ServiceDiscovery` instance. By default the discovery protocol is mounted on the switch so the node can answer inbound 
service-discovery requests. When `SD_CLIENT=true`, the discovery instance runs in DHT client mode instead: it is started 
locally but is not mounted as an inbound protocol.

After the switch starts, non-bootstrap roles wait for the configured startup jitter, connect to the bootstrap service, 
add the connected bootstrap peers to the discovery routing table, and run `bootstrap`. Bootstrap nodes only stay online 
as discovery anchors.

The active role then decides the long-running behavior:

- `RoleBootstrap` keeps the node alive for other peers to connect to.
- `RoleAdvertiser` publishes the configured `ADVERTISE_SERVICES`.
- `RoleDiscoverer` periodically looks up `DISCOVER_SERVICES`.
- `RoleHybrid` both advertises and periodically discovers services.

The health server starts after bootstrap setup and exposes `/health` and `/ready`.

## Environment variables

- `PORT` default `5000`
- `MUXER` default `yamux` (`yamux`, `mplex`, `quic`)
- `NODE_ROLE` default `RoleBootstrap` (`RoleBootstrap`, `RoleAdvertiser`, `RoleDiscoverer`, `RoleHybrid`)
- `SERVICE` bootstrap service DNS/address with optional port, default `service-discovery:5000`
- `ADVERTISE_SERVICES` comma-separated service ids (required for `RoleAdvertiser` and `RoleHybrid`)
- `DISCOVER_SERVICES` comma-separated service ids (required for `RoleDiscoverer` and `RoleHybrid`)
- `SERVICE_DATA` payload attached to advertised services (default empty)
- `LOOKUP_INTERVAL_SECONDS` default `15`
- `HEALTH_PORT` default `8645`
- `STARTUP_JITTER_MS` optional fixed jitter in milliseconds
- `STARTUP_JITTER_STEP_MS` default `200` (used when `STARTUP_JITTER_MS` is not set)
- `SD_SAFETY_PARAM` default `0.0` (0 means immediate confirmations are easier in tests)
- `SD_ADVERT_EXPIRY_SECONDS` default `900`
- `SD_CLIENT` default `false` (run service discovery as a DHT client, without mounting an inbound handler)
- `SD_XPR_PUBLISHING` default `true`

## Run examples

1. Bootstrap:

```bash
NODE_ROLE=RoleBootstrap PORT=5001 HEALTH_PORT=8645 ./main
```

2. Advertiser:

```bash
NODE_ROLE=RoleAdvertiser \
PORT=5002 \
SERVICE=127.0.0.1:5001 \
ADVERTISE_SERVICES=chat,mail \
SERVICE_DATA=status \
HEALTH_PORT=8647 \
./main
```

3. Discoverer:

```bash
NODE_ROLE=RoleDiscoverer \
PORT=5003 \
SERVICE=127.0.0.1:5001 \
DISCOVER_SERVICES=chat,mail \
LOOKUP_INTERVAL_SECONDS=10 \
HEALTH_PORT=8648 \
./main
```

4. Hybrid (advertise + discover):

```bash
NODE_ROLE=RoleHybrid \
PORT=5004 \
SERVICE=127.0.0.1:5001 \
ADVERTISE_SERVICES=chat \
DISCOVER_SERVICES=chat \
HEALTH_PORT=8649 \
./main
```

Health endpoints:

- `/health`
- `/ready`
