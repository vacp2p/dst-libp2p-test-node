import chronos
import std/[tables, sets]

import libp2p
import libp2p/protocols/ping
import libp2p/protocols/pubsub/gossipsub

const
  MeshPingInterval = 45.seconds
  MeshPingTimeout  = 4.seconds

proc meshPeerIds*(gossipSub: GossipSub, topic: string): seq[PeerId] =
  ## Only peers in the mesh for `topic` (convert HashSet[PubSubPeer] -> seq[PeerId])
  let peers: HashSet[PubSubPeer] = gossipSub.mesh.getOrDefault(topic, initHashSet[PubSubPeer]())
  result = newSeqOfCap[PeerId](peers.len)
  for p in peers:
    result.add(p.peerId)

proc pingMeshPeer*(switch: Switch, pingProtocol: Ping, peerId: PeerId) {.async.} =
  let book = switch.peerStore[AddressBook]

  if not book.book.hasKey(peerId):
    return

  let addrs = book[peerId]
  if addrs.len == 0:
    return

  var stream: Stream
  try:
    stream = await switch.dial(peerId, addrs, PingCodec)
    let latency = await pingProtocol.ping(stream).wait(MeshPingTimeout)
    info "mesh ping", peerId = peerId, latency = latency
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "mesh ping failed", peerId = peerId, error = exc.msg
  finally:
    if not stream.isNil and not stream.closed:
      try: await stream.close()
      except CancelledError as exc: raise exc
      except CatchableError: discard

proc pingMeshOnce*(switch: Switch, pingProtocol: Ping, gossipSub: GossipSub, topic: string) {.async.} =
  let peers = gossipSub.meshPeerIds(topic)
  if peers.len == 0:
    return

  var futs: seq[Future[void]] = @[]
  for pid in peers:
    if pid == switch.peerInfo.peerId: continue
    futs.add(switch.pingMeshPeer(pingProtocol, pid))

  if futs.len > 0:
    await allFutures(futs)

proc pingMeshLoop*(switch: Switch, pingProtocol: Ping, gossipSub: GossipSub, topic: string) {.async.} =
  while true:
    await switch.pingMeshOnce(pingProtocol, gossipSub, topic)
    await sleepAsync(MeshPingInterval)
