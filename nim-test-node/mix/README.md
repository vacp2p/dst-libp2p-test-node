# Mix test node

A standalone nim-libp2p [Mix](https://github.com/logos-co/nim-libp2p-mix) node —
Mix mounted on a libp2p switch with an auto-ping loop to generate traffic.

Intended as a deployment target for cluster-side analysis:
nodes run with full observability,
external clients can use the node's published key material to construct sphinx packets,
and per-hop logs from the Mix library record the "global passive observer" view of every packet.

For a Waku-stack smoke test of Mix,
see `logos-messaging/logos-delivery/simulations/mixnet/`.
The two are complementary:
this one isolates Mix at the libp2p layer;
the other runs Waku Lightpush over Mix.

## Behavior

Each Mix node:

- Generates a fresh Curve25519 mix keypair + secp256k1 libp2p keypair on startup.
- Writes its `MixPubInfo` (peerId, multiaddr, public keys) to a shared filesystem at `$FILEPATH/pubInfo_<myId>.json`.
- After `STARTSLEEP`, polls for peers' pubInfo files and populates the Mix nodePool.
- Dials a subset of peers (`CONNECTTO` count) to maintain libp2p transport for sphinx hops.
- Runs `periodicMixPing`: every 30s, pings every peer in the nodePool via Mix tunnels and logs RTT.

The auto-ping is the only traffic source.

## Quick start

Build the release image (from the `dst-libp2p-test-node` repo root):

```sh
docker build --platform linux/amd64 \
  -f nim-test-node/mix/Dockerfile_amd64 \
  -t dst-test-node-mix:wip \
  nim-test-node/mix/
```

First-time build is slow (full nim release compile).
Subsequent builds reuse the BuildKit cache mount and recompile only changed sources;
the dep install re-runs whenever Docker's layer cache has been pruned.

For fast local iteration there's `Dockerfile_amd64_dev` —
drops `-d:release` so the compile step is substantially faster,
at the cost of a debug (larger, slower) binary.
The speedup is real when the layer cache is warm;
from cold cache, build time matches the release image.
Use for smoke and local exploration;
the release image is the one for latency-sensitive measurement.

```sh
docker build --platform linux/amd64 \
  -f nim-test-node/mix/Dockerfile_amd64_dev \
  -t dst-test-node-mix-dev:wip \
  nim-test-node/mix/
```

`mixnet.sh` defaults to the release image (`dst-test-node-mix:wip`);
override per-invocation with `IMAGE=dst-test-node-mix-dev:wip ./mixnet.sh ...`.

Use the `mixnet.sh` script for everything else:

```sh
cd nim-test-node/mix
./mixnet.sh up 5             # spawn 5 Mix nodes
./mixnet.sh logs pod-1       # tail one node's logs
./mixnet.sh down             # stop pods, remove network + pubInfo volume
./mixnet.sh smoke            # spin up N=5, wait, assert mix-ping flows
```

A successful `smoke` finishes with `=== Smoke PASS ===` and exits 0;
failure ends in `=== Smoke FAIL ===` and exits non-zero.

## What to look for in logs

```sh
docker logs pod-1 2>&1 | grep -E 'Mix nodePool|Connected|mix-ping'
```

Useful patterns:

- `Mix nodePool populated count=N` — node read N-1 peer pubInfo files and built its Mix pool
- `Connected!: current connections connected=N` — libp2p dial succeeded
- `mix-ping ok target=... rtt=...` — auto-ping verified Mix routing end-to-end
- `Mix nodePool incomplete after polling` — slow peers; raise `STARTSLEEP` or lower `NUMMIX`

## Env vars

| Var | Default | Notes |
|---|---|---|
| `NUMMIX` | `PEERS` | Number of Mix nodes; mix nodes must be pods `0..NUMMIX-1` |
| `PEERS` | `100` | Total network size |
| `CONNECTTO` | `10` | Libp2p connections to dial |
| `STARTSLEEP` | `180` | Seconds to wait before polling for peers (raise for large N) |
| `FILEPATH` | `./` (binary), `/data` (image) | Where pubInfo_*.json files live; bind-mount the same path across pods |
| `LOCALSMOKE` | `false` | `true` for local-smoke `pod-N` hostname iteration; `false` for K8s service DNS (set by `mixnet.sh` for the local smoke; do not set in production) |

Shares env-var conventions with `regression/`;
see `regression/env.nim` for any vars not listed above.

## Out of scope

RLN spam protection, cover traffic, bootstrap-based discovery, service discovery, pluggable/configurable traffic patterns.
See the Mix spec at `logos-co/logos-lips/docs/anoncomms/raw/mix.md`.
