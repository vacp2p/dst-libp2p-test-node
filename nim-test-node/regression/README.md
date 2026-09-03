# Regression test node

This folder contains the Nim libp2p node used for regression campaigns. It can
build two kinds of node from the same source:

- a normal GossipSub test node
- a bootstrap node used as the Kad-DHT anchor

## How it works

The bootstrap node starts first. It listens on the libp2p port and runs Kad-DHT
so the other nodes have a stable peer to dial.

Normal nodes start with ping, Kad-DHT, GossipSub, metrics, and an HTTP publish
endpoint. Each normal node resolves the bootstrap service, dials it, seeds that
peer into its Kad-DHT routing table, and then uses Kad-DHT discovery to find the
rest of the network. GossipSub builds its mesh from those connections.

The publish controller sends HTTP requests to each normal node on port `8645`.
The node publishes a timestamped message to the `test` topic. Receivers log the
message delay and expose metrics on port `8008`.

## Main files

- `node/main.nim`: normal GossipSub node. It owns message publishing, message
  handling, the HTTP publish endpoint, metrics startup, bootstrap dialing, and
  the keepalive ping loop.
- `bootstrap/main.nim`: bootstrap node. It mounts ping and Kad-DHT only, then
  waits for normal nodes to connect.
- `node_setup.nim`: shared switch setup. It creates the libp2p switch and mounts
  the protocols used by both node types.
- `env.nim`: reads environment variables, derives the pod index from the
  hostname, chooses the listen address, and starts the metrics server.
- `kad_utils.nim`: resolves and dials the bootstrap service, mounts Kad-DHT, and
  seeds bootstrap peers into the routing table.
- `ping_utils.nim`: keeps idle connections alive before GossipSub traffic starts.
- `test_node.nimble`: Nim package definition and pinned dependencies.
- `Dockerfile`: simple normal Docker build for the current Docker target
  platform.
- `Dockerfile_shadow`: Shadow-specific Docker build. It creates a dynamically
  linked amd64 binary and applies the lsquic tick-floor patch.

## Building the normal Docker images

The normal Dockerfile can build four image variants:

```bash
# amd64 normal node
docker buildx build --platform linux/amd64 -f Dockerfile -t regression-node-amd64 --load .

# amd64 bootstrap node
docker buildx build --platform linux/amd64 -f Dockerfile --build-arg NODE_BINARY=bootstrap -t regression-bootstrap-amd64 --load .

# arm64 normal node
docker buildx build --platform linux/arm64 -f Dockerfile -t regression-node-arm64 --load .

# arm64 bootstrap node
docker buildx build --platform linux/arm64 -f Dockerfile --build-arg NODE_BINARY=bootstrap -t regression-bootstrap-arm64 --load .
```

The container entrypoint is always `/node/main`, even for the bootstrap image.
That keeps deployment manifests simple; the image contents decide which node
type runs. The default build is `NODE_BINARY=node`, so only the bootstrap image
needs the build arg.

For a registry push, replace `--load` with `--push` and use the full registry
image name:

```bash
docker buildx build --platform linux/amd64 -f Dockerfile -t <registry>/regression-node-amd64:<tag> --push .
```

Example:

```bash
docker buildx build --platform linux/amd64 -f Dockerfile -t ghcr.io/vacp2p/dst-libp2p-test-node/regression-node:v0.1.0 --push .
```

## Runtime knobs

- `MUXER`: transport/muxer to use: `yamux`, `mplex`, or `quic`. Default:
  `yamux`.
- `SERVICE`: bootstrap service DNS name used by normal nodes. Default:
  `bootstrap`.
- `MAXCONNECTIONS`: maximum libp2p connections. Default: `250`.
- `SELFTRIGGER`: whether GossipSub receives its own publishes. Default: `true`.
- `FRAGMENTS`: number of fragments per message. Default: `1`.
- `STARTUP_JITTER_STEP_MS`: per-pod startup delay before dialing bootstrap.
  Default: `50`.
- `SHADOWENV`: set to `true` when running in Shadow.
- `METRICS_INTERVAL_S`: scrape interval for storing metrics in Shadow. Default:
  `300`.

## The lsquic tick-floor patch (Shadow + quic only)

`lsquic-tick-floor.patch`, applied by `Dockerfile_shadow`, is the reason
quic runs under Shadow at all. lsquic re-arms its engine tick with a zero delay;
in a discrete-event simulator that self-rescheduling timer never lets simulated
time advance, so the run livelocks at one instant. mplex and yamux are fine.

The patch floors the re-arm interval, gated by `LSQUIC_TICK_FLOOR_US` (unset/0 =
stock, so the image is safe on the cluster too; campaigns use `10000`, 10 ms).
`es_clock_granularity` is a real lsquic setting, but the essential change floors
nim-lsquic's own chronos re-arm, which has no upstream knob; the durable fix is
exposing both upstream in nim-lsquic.

## Maintaining the patch

It targets lsquic 0.5.4's layout, pinned in `test_node.nimble`. `nimble c`
re-resolves deps before compiling, so the Dockerfile patches the package cache
(`~/.nimble/pkgcache`, what nimble copies from) rather than the installed copy.
The build asserts it patched something and greps the binary for
`LSQUIC_TICK_FLOOR_US`, so a stock build or a stale pin fails loudly.


## Images:
- v2.0.0
  - Node: 
    - `albertodst/regression-node-amd64:v2.0.0`
    - `albertodst/regression-node-arm64:v2.0.0`
  - Bootstrap: 
    - `albertodst/regression-bootstrap-amd64:v2.0.0`
    - `albertodst/regression-bootstrap-arm64:v2.0.0`
- v2.1.6
  - Node:
    - `albertodst/regression-node-amd64:v2.1.6`
    - `albertodst/regression-node-arm64:v2.1.6`
  - Bootstrap:
    - `albertodst/regression-bootstrap-amd64:v2.1.6`
    - `albertodst/regression-bootstrap-arm64:v2.1.6`