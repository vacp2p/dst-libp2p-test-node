import chronos
import std/[tables, sets]

import libp2p
import libp2p/protocols/ping
import libp2p/protocols/pubsub/gossipsub

const
  MeshPingInterval = 45.seconds
  MeshPingTimeout  = 4.seconds
  MeshDialTimeout  = 4.seconds
  MeshCloseTimeout = 2.seconds
  SlowDialLog      = 500.milliseconds
  SlowCloseLog     = 500.milliseconds

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
  let dialStart = Moment.now()
  try:
    stream = await switch.dial(peerId, addrs, PingCodec).wait(MeshDialTimeout)

    let dialDur = Moment.now() - dialStart
    if dialDur >= SlowDialLog:
      warn "mesh ping: slow dial", peerId = peerId, dialMs = dialDur.milliseconds

    let pingStart = Moment.now()
    let latency = await pingProtocol.ping(stream).wait(MeshPingTimeout)
    let pingDur = Moment.now() - pingStart

    info "mesh ping",
      peerId = peerId,
      latency = latency,
      dialMs = dialDur.milliseconds,
      pingMs = pingDur.milliseconds
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    let dialDur = Moment.now() - dialStart
    warn "mesh ping failed", peerId = peerId, error = exc.msg, dialMs = dialDur.milliseconds
  finally:
    if not stream.isNil and not stream.closed:
      let closeStart = Moment.now()
      try:
        # Make close observable: if it never completes, you'll never see "slow close" today.
        await stream.closeWithEOF().wait(MeshCloseTimeout)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        warn "mesh ping: stream close failed", peerId = peerId, error = exc.msg
      finally:
        let closeDur = Moment.now() - closeStart
        if closeDur >= SlowCloseLog:
          warn "mesh ping: slow close", peerId = peerId, closeMs = closeDur.milliseconds

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
