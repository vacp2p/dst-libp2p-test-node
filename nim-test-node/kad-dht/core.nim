import
  libp2p, libp2p/[muxers/mplex/lpchannel, stream/connection, crypto/secp, multiaddress]
import libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]
import libp2p/protocols/[kademlia, kad_disco]
import sequtils, math, metrics, metrics/chronos_httpserver
import chronicles
import env
import helpers
import ../common/peer_ids

logScope:
  topics = "dst"

from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds

# --- Core Logic ---

proc runWarmup*[R](kad: KadDHT, selfId: PeerId, rng: R) {.async.} =
  info "Starting warmup phase"

  # 5x FIND_NODE(self)
  for i in 1 .. 5:
    debug "Warmup: Finding self", iteration = i
    let peers = await kad.findNode(selfId.toKey())
    var rtPeers = 0
    for b in kad.rtable.buckets:
      rtPeers += b.peers.len

    debug "Kad routing table", peers = rtPeers, buckets = kad.rtable.buckets.len

    await sleepAsync(1.seconds)

  # 15x FIND_NODE(random)
  for i, target in randomPeerIds(rng, 15):
    debug "Warmup: Finding random node", iteration = i + 1, target = target

    let peers = await kad.findNode(target.toKey())

    await sleepAsync(2.seconds)

  info "Warmup complete"

proc runProbe*[R](kad: KadDHT, rng: R) {.async.} =
  info "Starting probe loop"
  while true:
    let
      targetPeer = randomPeerId(rng)
      targetKey = targetPeer.toKey()

    try:
      info "Probe: Finding node", target = $targetPeer
      let peers = await kad.findNode(targetKey).wait(30.seconds)
    except CatchableError as exc:
      warn "Probe Failed", target = $targetPeer, success = false, error = exc.msg

    await sleepAsync(5.seconds)
