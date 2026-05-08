## Service Discovery Test Node

This folder contains a standalone node to exercise `libp2p/protocols/service_discovery.nim`
in local setups or Kubernetes.

## Compile

From this folder:

```bash
nimble c \
  -d:chronicles_colors=None \
  --threads:on \
  --mm:refc \
  -d:metrics \
  -d:libp2p_network_protocols_metrics \
  -d:release \
  -d:chronicles_log_level:NOTICE \
  main
```

If you need local `nim-libp2p` changes, keep `nimble.paths` pointing to your local repo root.

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
- `SD_XPR_PUBLISHING` default `true`

## Run examples

1. Bootstrap:

```bash
NODE_ROLE=RoleBootstrap PORT=5001 ./main
```

2. Advertiser:

```bash
NODE_ROLE=RoleAdvertiser \
PORT=5002 \
SERVICE=127.0.0.1:5001 \
ADVERTISE_SERVICES=chat,mail \
SERVICE_DATA=status \
./main
```

3. Discoverer:

```bash
NODE_ROLE=RoleDiscoverer \
PORT=5003 \
SERVICE=127.0.0.1:5001 \
DISCOVER_SERVICES=chat,mail \
LOOKUP_INTERVAL_SECONDS=10 \
./main
```

4. Hybrid (advertise + discover):

```bash
NODE_ROLE=RoleHybrid \
PORT=5004 \
SERVICE=127.0.0.1:5001 \
ADVERTISE_SERVICES=chat \
DISCOVER_SERVICES=chat \
./main
```

Health endpoints:

- `/health`
- `/ready`
