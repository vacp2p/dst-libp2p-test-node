import stew/endians2, stew/byteutils, tables, strutils, os, json
import chronos, chronos/apps/http/httpserver
import env
import std/[strformat, random, hashes]
import libp2p, libp2p/[muxers/mplex/lpchannel, stream/connection, crypto/secp, multiaddress]
import libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]
import libp2p/protocols/kademlia

import sequtils, math, metrics, metrics/chronos_httpserver
from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname
# --- Configuration & Types ---

type
  NodeType = enum
    RoleBootstrap, RoleNormal, RoleProbe

# --- Helpers ---

proc getRandomPeerId(): PeerId =
  # Generates a random peer ID for FIND_NODE targets
  let rng = newRng()
  return PeerId.init(PrivateKey.random(Secp256k1, rng[]).get()).get()

proc logFindNodeResult(tag: string, target: PeerId, peers: seq[PeerId]) =
  info "findNode result", tag = tag, target = $target, count = peers.len
  for i, p in peers:
    info "findNode peer", tag = tag, i = i, peer = $p


# --- Core Logic ---

proc runWarmup(kad: KadDHT, selfId: PeerId) {.async.} =
  notice "Starting warmup phase"

  # 5x FIND_NODE(self)
  for i in 1..5:
    notice "Warmup: Finding self", iteration = i
    let peers = await kad.findNode(selfId.toKey())
    logFindNodeResult("warmup-self", selfId, peers)

    await sleepAsync(1.seconds)

  # 15x FIND_NODE(random)
  for i in 1..15:
    let target = getRandomPeerId()
    notice "Warmup: Finding random node", iteration = i, target = target
    discard await kad.findNode(target.toKey())
    # Optional: Dial a few returned peers to populate routing table
    await sleepAsync(2.seconds)

  notice "Warmup complete"

# proc runProbe(kad: KadDHT) {.async.} =
#   notice "Starting probe loop"
#   while true:
#     let
#       target = getRandomPeerId()
#       start = getTime()
#
#     try:
#       # findNode returns seq[PeerInfo]
#       let peers = await kad.findNode(target).wait(30.seconds)
#       let duration = (getTime() - start).inMilliseconds()
#
#       notice "Probe Result",
#         target = $target,
#         success = true,
#         duration_ms = duration,
#         peers_found = peers.len,
#         closer_peers = peers.mapIt($it.peerId)
#
#     except CatchableError as exc:
#       let duration = (getTime() - start).inMilliseconds()
#       warn "Probe Failed",
#         target = $target,
#         success = false,
#         duration_ms = duration,
#         error = exc.msg
#
#     await sleepAsync(10.seconds) # Sample every 10s

proc main {.async.} =

  let
    nodeRole = parseEnum[NodeType](getEnv("NODE_ROLE", "RoleNormal"))
    service = getEnv("SERVICE", "kad-service:5000")
    isServer = nodeRole in {RoleBootstrap, RoleNormal}

  randomize()
  let
    rng = libp2p.newRng()
    (myId, muxer, address) = getPeerDetails().valueOr:
      error "Error reading peer settings ",  err = error
      return

  # 1. Setup Networking
  var switch = SwitchBuilder
    .new()
    .withNoise()
    .withRng(crypto.newRng())
    .withAddresses(@[MultiAddress.init(address).tryGet()])
    .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
    .withYamux()
    .build()

  # 2. Initialize DHT
  let kad = KadDHT.new(
    switch,
    # bootstrapNodes = @[(otherPeerId, @[MultiAddress.init(otherAddr).get()])],
    config = KadDHTConfig.new(),
  )
  switch.mount(kad)
  await switch.start()

  let selfId = switch.peerInfo.peerId
  notice "Node started", peerId = selfId, role = nodeRole, listen = address
#
  ## 3. Connect to Bootstraps (Staggered)
  #if nodeRole != RoleBootstrap:
  #  # Randomized sleep
  #  let delay = rand(100..150)
  #  debug "Staggered join", delay_ms = delay
  #  await sleepAsync(delay.milliseconds)
#
  #  for b in bootstrapAddrs:
  #    try:
  #      let ma = MultiAddress.init(b).get()
  #      await switch.connect(ma)
  #      notice "Connected to bootstrap", address = b
  #    except CatchableError as exc:
  #      warn "Failed to connect to bootstrap", address = b, error = exc.msg
#
  # 4. Role-based execution
  case nodeRole
  of RoleBootstrap:
    # Just stay alive and serve queries
    while true: await sleepAsync(1.hours)

  of RoleNormal:
    await runWarmup(kad, selfId)
    # Keep node alive for steady state refresh
    while true: await sleepAsync(1.hours)

  of RoleProbe:
    #await runWarmup(kad, selfId) # Probes also need a routing table
    #await runProbe(kad)
    while true: await sleepAsync(1.hours)

waitFor(main())


# KadDHTConfig(
#   validator: validator,
#   selector: selector,
#   timeout: timeout,
#   bucketRefreshTime: bucketRefreshTime,
#   retries: retries,
#   replication: replication,
#   alpha: alpha,
#   quorum: quorum,
#   providerRecordCapacity: providerRecordCapacity,
#   providedKeyCapacity: providedKeyCapacity,
#   republishProvidedKeysInterval: republishProvidedKeysInterval,
#   cleanupProvidersInterval: cleanupProvidersInterval,
#   providerExpirationInterval: providerExpirationInterval,
# )
