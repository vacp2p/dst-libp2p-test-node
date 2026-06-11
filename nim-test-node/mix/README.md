# mix test node

A nim-libp2p test node with [mix protocol](https://github.com/logos-co/nim-libp2p-mix) support,
forked from `regression/`.
Mix is the focus;
GossipSub is exercised as a protocol whose publishes can be routed through Mix.

For a Waku-stack smoke test of Mix,
see `logos-messaging/logos-delivery/simulations/mixnet/`.
The two are complementary:
this one isolates Mix at the libp2p layer;
the other runs Waku Lightpush over Mix.

## Mode matrix

Config is set at startup via env vars and applies to every message during the node's lifetime:

| `MIXENABLED` | `GOSSIPSUBMODE` | Behaviour |
|---|---|---|
| `false` | `regular` | GossipSub publishes flow direct (no Mix) |
| `false` | `anonymous` | **Rejected at startup** (validation) |
| `false` | `off` | Bare libp2p switch (silent) |
| `true` | `regular` | Mix mounted but unused by GossipSub; publishes flow direct |
| `true` | `anonymous` | **Main feature**: GossipSub publishes routed through Mix |
| `true` | `off` | No GossipSub; auto-ping is the only traffic |

Whenever `MIXENABLED=true`,
an auto-ping loop (`mix_ping.nim`) pings every peer in the nodePool every 30s and logs RTT.
In `off` it's the sole traffic source;
in `regular` and `anonymous` it runs alongside GossipSub.

## Quick start

Build the release image (from the `dst-libp2p-test-node` repo root):

```sh
docker build --platform linux/amd64 \
  -f nim-test-node/mix/Dockerfile_amd64_shadow \
  -t dst-test-node-mix-shadow:wip \
  nim-test-node/mix/
```

First-time build is slow (full nim release compile).
Subsequent builds reuse the BuildKit cache mount and recompile only changed sources;
the dep install re-runs whenever Docker's layer cache has been pruned.

For fast local iteration there's `Dockerfile_amd64_dev` —
drops `-d:release` so the compile step is substantially faster,
at the cost of a debug (larger, slower) binary.
The speedup is real when the layer cache is warm;
from cold cache, build time matches Shadow.
Smoke and local exploration only;
never for Shadow runs or latency measurements.

```sh
docker build --platform linux/amd64 \
  -f nim-test-node/mix/Dockerfile_amd64_dev \
  -t dst-test-node-mix-dev:wip \
  nim-test-node/mix/
```

`mixnet.sh` defaults to the Shadow image;
override per-invocation with `IMAGE=dst-test-node-mix-dev:wip ./mixnet.sh ...`.

Use the `mixnet.sh` script for everything else:

```sh
cd nim-test-node/mix
./mixnet.sh up 5             # spawn 5 nodes, GossipSub direct
./mixnet.sh up 5 anonymous   # spawn 5 nodes, route GossipSub publishes through mix
./mixnet.sh publish 0        # POST to pod-0:8645/publish
./mixnet.sh logs pod-1       # tail one node's logs
./mixnet.sh down             # stop pods, remove network + pubInfo volume
./mixnet.sh smoke            # validation reject + true/anonymous E2E delivery
./mixnet.sh smoke-all        # full 6-cell matrix walk, exits non-zero on any failure
```

For manual exploration:
after `up`,
wait for `STARTSLEEP` + the Mix nodePool poll to complete (look for `Mix nodePool populated` in the logs) before calling `publish`.
`smoke` and `smoke-all` wait internally —
only manual flows need this.

A successful `smoke` finishes with `=== Smoke PASS ===` and exits 0;
failure ends in `=== Smoke FAIL ===` and exits non-zero.

## What to look for in logs

```sh
docker logs pod-1 2>&1 | grep -E 'Mix nodePool|Connected|Mesh details|Received message|mix-ping'
```

Useful patterns:

- `Mix nodePool populated count=N` — node read N-1 peer pubInfo files and built its Mix pool
- `Connected!: current connections connected=N` — direct libp2p dial succeeded
- `Mesh details meshSize=N peersConnected=N` — GossipSub mesh formed
- `Received message msgId=... delayMs=X` — GossipSub message delivered, `X` is end-to-end delay
- `mix-ping ok target=... rtt=...` — auto-ping verified Mix routing (Mix-only mode)
- `Mix nodePool incomplete after polling` — slow peers; raise `STARTSLEEP` or lower `NUMMIX`

## Env vars

| Var | Default | Notes |
|---|---|---|
| `MIXENABLED` | `false` | When `false`, no Mix protocol is mounted |
| `GOSSIPSUBMODE` | `regular` | `regular` / `anonymous` / `off` |
| `NUMMIX` | `PEERS` | Number of Mix-capable nodes; Mix nodes must be pods `0..NUMMIX-1` (the rest run with `MIXENABLED=false`) |
| `PEERS` | `100` | Total network size |
| `CONNECTTO` | `10` | Libp2p connections to dial |
| `STARTSLEEP` | `180` | Seconds to wait before dialing (raise for large N) |
| `FILEPATH` | `./` (binary), `/data` (image) | Where pubInfo_*.json files live; bind-mount the same path across pods |
| `SHADOWENV` | `false` | `true` for hostname iteration (`pod-N`); `false` for K8s service DNS |

Shares env-var conventions with `regression/`;
see `regression/env.nim` for the full list.

## Extending: a new protocol over Mix

The pattern is set by `mix_ping.nim`.
To add `mix_<myproto>.nim`:

1. Create the new file mirroring `mix_ping.nim`'s shape:
   - `proc setup(switch, mixProto, rng): MyProto {.raises: [LPError].}` — mount
     the protocol on the switch and `mixProto.registerDestReadBehavior(MyCodec, ...)`
   - Optionally a periodic-driver proc to exercise it

2. Add one line in `main.nim`:
   ```nim
   import ./mix_myproto
   ...
   if mixEnabled:
     let myProto = mix_myproto.setup(switch, mixProto, rng)
   ```

Out of V1 scope: RLN spam protection, cover traffic, bootstrap-based discovery.
See the Mix spec at `logos-co/logos-lips/docs/anoncomms/raw/mix.md`.
