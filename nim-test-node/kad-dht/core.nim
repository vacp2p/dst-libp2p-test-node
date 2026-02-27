import libp2p, libp2p/[muxers/mplex/lpchannel, stream/connection, crypto/secp, multiaddress]
import libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]
import libp2p/protocols/[kademlia, kad_disco]
import sequtils, math, metrics, metrics/chronos_httpserver
import env
import helpers

from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds

# --- Core Logic ---

proc runWarmup*(kad: KadDHT, selfId: PeerId) {.async.} =
  notice "Starting warmup phase"

  # 5x FIND_NODE(self)
  for i in 1..5:
    debug "Warmup: Finding self", iteration = i
    let peers = await kad.findNode(selfId.toKey())
    var rtPeers = 0
    for b in kad.rtable.buckets:
      rtPeers += b.peers.len

    debug "Kad routing table", peers = rtPeers, buckets = kad.rtable.buckets.len

    logFindNodeResult("warmup-self", selfId, peers)

    await sleepAsync(1.seconds)

  # 15x FIND_NODE(random)
  for i in 1..15:
    let target = getRandomPeerId()
    debug "Warmup: Finding random node", iteration = i, target = target

    let peers = await kad.findNode(target.toKey())
    logFindNodeResult("warmup-random", target, peers)

    await sleepAsync(2.seconds)

  notice "Warmup complete"

proc connectToBootstraps*(switch: Switch, muxer: string, service: string) {.async.} =
  let addrsRes = await resolveService(muxer, service)
  let addrs = addrsRes.valueOr:
    error "Failed to resolve bootstrap service", service = service, error = error
    return

  for addr in addrs:
    try:
      discard await switch.connect(addr, allowUnknownPeerId=true)
      notice "Connected to bootstrap", address = addr
      await sleepAsync(2.seconds)
    except CatchableError as exc:
      warn "Failed to connect to bootstrap", address = addr, error = exc.msg


proc runProbe*(kad: KadDHT) {.async.} =
  notice "Starting probe loop"
  while true:
    let
      targetPeer = getRandomPeerId()
      targetKey = targetPeer.toKey()
      start = getTime()

    try:
      let peers = await kad.findNode(targetKey).wait(30.seconds)
      logFindNodeResult("runProbe", targetPeer, peers)
      let duration = (getTime() - start).inMilliseconds()
      notice "Probe Result",
        target = $targetPeer,
        success = true,
        duration_ms = duration,
        peers_found = peers.len,
        closer_peers = peers.mapIt($it)

    except CatchableError as exc:
      let duration = (getTime() - start).inMilliseconds()
      warn "Probe Failed",
        target = $targetPeer,
        success = false,
        duration_ms = duration,
        error = exc.msg

    await sleepAsync(10.seconds)
