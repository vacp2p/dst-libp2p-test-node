import chronos
import std/[random, tables]

import libp2p
import libp2p/protocols/ping

const
  PingInterval  = 12.seconds
    ## A full sweep in batches takes a few seconds, so the gap between two pings of the
    ## same peer is the interval plus a sweep. Keep that comfortably under quic's 30s
    ## idle timeout.
  PingBatch     = 16
    ## Dials in flight at once. All ~250 together stalls the node's own publish
    ## endpoint, which cost 34 injections in the first minute of a 1000-node run.
  PingBatchGap  = 200.milliseconds
  PingTimeout   = 4.seconds
  DialTimeout   = 4.seconds
  CloseTimeout  = 2.seconds
  SlowDialLog   = 500.milliseconds
  SlowCloseLog  = 500.milliseconds

var messagesStarted = false

proc notePublishingStarted*() =
  ## Called from the message handler; stops the ping loop.
  messagesStarted = true

proc connectedPeerIds*(switch: Switch): seq[PeerId] =
  ## Every peer we hold a connection to, not just the gossipsub mesh.
  let conns = switch.connManager.getConnections()
  result = newSeqOfCap[PeerId](conns.len)
  for peerId in conns.keys:
    result.add(peerId)

proc pingPeer*(switch: Switch, pingProtocol: Ping, peerId: PeerId) {.async.} =
  let book = switch.peerStore[AddressBook]

  if not book.book.hasKey(peerId):
    return

  let addrs = book[peerId]
  if addrs.len == 0:
    return

  var stream: Connection
  let dialStart = Moment.now()
  try:
    stream = await switch.dial(peerId, addrs, PingCodec).wait(DialTimeout)

    let dialDur = Moment.now() - dialStart
    if dialDur >= SlowDialLog:
      warn "keepalive ping: slow dial", peerId = peerId, dialMs = dialDur.milliseconds

    let pingStart = Moment.now()
    let latency = await pingProtocol.ping(stream).wait(PingTimeout)
    let pingDur = Moment.now() - pingStart

    trace "keepalive ping",
      peerId = peerId,
      latency = latency,
      dialMs = dialDur.milliseconds,
      pingMs = pingDur.milliseconds
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    let dialDur = Moment.now() - dialStart
    warn "keepalive ping failed", peerId = peerId, error = exc.msg, dialMs = dialDur.milliseconds
  finally:
    if not stream.isNil and not stream.closed:
      let closeStart = Moment.now()
      try:
        # Make close observable: if it never completes, you'll never see "slow close" today.
        await stream.closeWithEOF().wait(CloseTimeout)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        warn "keepalive ping: stream close failed", peerId = peerId, error = exc.msg
      finally:
        let closeDur = Moment.now() - closeStart
        if closeDur >= SlowCloseLog:
          warn "keepalive ping: slow close", peerId = peerId, closeMs = closeDur.milliseconds

proc pingAllOnce*(switch: Switch, pingProtocol: Ping) {.async.} =
  var peers: seq[PeerId] = @[]
  for pid in switch.connectedPeerIds():
    if pid != switch.peerInfo.peerId:
      peers.add(pid)
  if peers.len == 0:
    return

  var i = 0
  while i < peers.len:
    if messagesStarted:
      return
    var futs: seq[Future[void]] = @[]
    for pid in peers[i ..< min(i + PingBatch, peers.len)]:
      futs.add(switch.pingPeer(pingProtocol, pid))
    await allFutures(futs)
    i += PingBatch
    if i < peers.len:
      await sleepAsync(PingBatchGap)

proc pingLoop*(switch: Switch, pingProtocol: Ping) {.async.} =
  ## Hold every connection open until traffic starts doing it for us.
  ##
  ## quic closes a connection after 30s of silence, and before the first message there
  ## is nothing to gossip about, so an idle cold start drops every connection that is
  ## not in the mesh. Once messages flow, gossip reaches each peer every few seconds and
  ## the ping is redundant, so it stops.
  # Stagger the start so a thousand nodes do not ping in lockstep.
  await sleepAsync(rand(PingInterval.milliseconds.int).milliseconds)
  while not messagesStarted:
    await switch.pingAllOnce(pingProtocol)
    await sleepAsync(PingInterval)
  info "keepalive ping stopped, gossipsub traffic now keeps connections open"
