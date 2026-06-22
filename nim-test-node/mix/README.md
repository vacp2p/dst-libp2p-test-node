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

## Kubernetes deployment

The deployment manifest is in `k8s/mix-statefulset.yaml`.
It creates:

- a `StatefulSet` named `mix`
- a headless `Service` named `mix` for stable pod DNS
- a shared `PersistentVolumeClaim` named `mix-pubinfos`
- a `mix-metrics` Service exposing port `8008`

The shared PVC must support `ReadWriteMany`.
This is required because every pod writes its own `pubInfo_<id>.json`
and reads the other pods' files from the same `FILEPATH`.
Examples of suitable storage backends are NFS, CephFS, EFS, or another RWX class
available in your cluster.

Build and push an image first:

```sh
docker build --platform linux/amd64 \
  -f nim-test-node/mix/Dockerfile_amd64 \
  -t <registry>/dst-test-node-mix:<tag> \
  nim-test-node/mix/
docker push <registry>/dst-test-node-mix:<tag>
```

Then edit `k8s/mix-statefulset.yaml`:

- set `image` to the image you pushed
- set `storageClassName` to an RWX-capable storage class; the checked-in manifest currently uses `longhorn`
- set `spec.replicas`, `PEERS`, and `NUMMIX` to the same value, for example `10` or `20`
- keep `CONNECTTO` lower than the replica count

Deploy:

```sh
kubectl apply -f nim-test-node/mix/k8s/mix-statefulset.yaml
kubectl -n mix rollout status statefulset/mix
kubectl -n mix logs -f mix-0
```

For 20 nodes, set:

```yaml
spec:
  replicas: 20
...
- name: PEERS
  value: "20"
- name: NUMMIX
  value: "20"
- name: CONNECTTO
  value: "10"
```

The checked-in manifest is configured for external NodePort publishing:
each pod publishes `$(HOST_IP):(31400 + pod ordinal)` in its `MixPubInfo`.
The node derives its numeric id from the StatefulSet pod hostname, so pod names
must end in the StatefulSet ordinal (`mix-0`, `mix-1`, ...).

### External access with NodePort

Do not share Pod IPs with external users.
Pod IPs are cluster-internal and can change when pods restart.
For coworkers outside the cluster, expose each pod through a stable external
address and make sure the same address is written into `MixPubInfo`.

The optional `k8s/mix-nodeports.yaml` manifest creates one fixed NodePort Service
per StatefulSet pod:

```text
mix-0  -> <node-external-ip-or-dns>:31400
mix-1  -> <node-external-ip-or-dns>:31401
...
mix-19 -> <node-external-ip-or-dns>:31419
```

For this mode, `k8s/mix-statefulset.yaml` publishes the Kubernetes node IP
that hosts each pod:

```yaml
- name: HOST_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
- name: PUBLISHED_HOSTNAME
  value: "$(HOST_IP)"
- name: PUBLISHED_PORT_BASE
  value: "31400"
```

The NodePort Services use `externalTrafficPolicy: Local`, so
`<published-host-ip>:<nodeport>` targets the pod running on that node.
This works only if `status.hostIP` is reachable by your coworkers.
In many clusters `status.hostIP` is a private node IP; in that case, replace
`PUBLISHED_HOSTNAME` with a public node DNS/IP, or use per-pod LoadBalancer
Services.

Then deploy both manifests:

```sh
kubectl apply -f nim-test-node/mix/k8s/mix-statefulset.yaml
kubectl apply -f nim-test-node/mix/k8s/mix-nodeports.yaml
```

Share the generated `/data/pubInfo_*.json` files, or their peer id, multiaddr,
and public key contents, with your coworkers.
Those files should contain the external NodePort addresses, not the Pod IPs.
For example, `pubInfo_0.json` should contain a multiaddr like
`/dns4/<node-external-dns>/tcp/31400` or `/ip4/<node-external-ip>/tcp/31400`.
If it contains `/ip4/10.x.x.x/tcp/5000`, the StatefulSet is still using the
cluster-internal publish settings or the image was built before external
publishing support was added.

This assumes your Kubernetes worker nodes have externally reachable IPs or DNS
names and that firewalls/security groups allow the chosen NodePort range
(`31400-31419` by default).
If external clients need to reach nodes through different public hosts, use
individual `PUBLISHED_PORT`/host settings or per-pod LoadBalancer Services
instead of one shared `PUBLISHED_HOSTNAME`.

## What to look for in logs

```sh
docker logs pod-1 2>&1 | grep -E 'Mix nodePool|Connected|mix-ping'
```

Useful patterns:

- `Mix nodePool populated count=N` — node read N-1 peer pubInfo files and built its Mix pool
- `Connected!: current connections connected=N` — libp2p dial succeeded
- `mix-ping ok target=... rtt=...` — auto-ping verified Mix routing end-to-end
- `Mix nodePool incomplete after polling` — slow peers; raise `STARTSLEEP` or lower `NUMMIX`
- `mix-ping disabled` — expected in the Kubernetes manifest; nodes still publish pubInfos and form libp2p connections

## Env vars

| Var | Default | Notes |
|---|---|---|
| `NUMMIX` | `PEERS` | Number of Mix nodes; mix nodes must be pods `0..NUMMIX-1` |
| `PEERS` | `100` | Total network size |
| `CONNECTTO` | `10` | Libp2p connections to dial |
| `STARTSLEEP` | `180` | Seconds to wait before polling for peers (raise for large N) |
| `FILEPATH` | `./` (binary), `/data` (image) | Where pubInfo_*.json files live; bind-mount the same path across pods |
| `PUBLISHED_HOSTNAME` | pod hostname | Hostname published in this node's `MixPubInfo`; set to the StatefulSet pod FQDN in K8s |
| `PUBLISHED_PORT` | `5000` | Port published in this node's `MixPubInfo`; overrides `PUBLISHED_PORT_BASE` |
| `PUBLISHED_PORT_BASE` | unset | When set, publishes `PUBLISHED_PORT_BASE + myId`; useful for per-pod NodePorts |
| `MIXPING` | `true` | Set to `false` to disable the periodic mix ping traffic source |
| `LOCALSMOKE` | `false` | `true` for local-smoke `pod-N` hostname iteration; `false` for K8s service DNS (set by `mixnet.sh` for the local smoke; do not set in production) |

Shares env-var conventions with `regression/`;
see `regression/env.nim` for any vars not listed above.

## Out of scope

RLN spam protection, cover traffic, bootstrap-based discovery, service discovery, pluggable/configurable traffic patterns.
See the Mix spec at `logos-co/logos-lips/docs/anoncomms/raw/mix.md`.
