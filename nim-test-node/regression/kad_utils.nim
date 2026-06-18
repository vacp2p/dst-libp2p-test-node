import chronos, chronicles
import sequtils, strutils
import libp2p
import libp2p/protocols/kademlia

import env

# kad-dht mesh formation: instead of statically dialing CONNECTTO peers, normal
# nodes connect to a bootstrap node, seed a Kademlia routing table from it, and
# let FIND_NODE lookups discover the rest of the network. GossipSub then grafts
# its mesh from the peers the DHT connected us to.

const
  BootstrapDialTimeout = 10.seconds

proc resolveBootstrapAddrs(
    muxer: string, service: string
): Future[Result[seq[MultiAddress], string]] {.async.} =
  # `service` is a k8s DNS name, optionally with a port; default to myPort.
  let tAddress = if ':' in service: service else: service & ":" & $myPort
  try:
    let resolved =
      if muxer.toLowerAscii() == "quic":
        let quicV1 = MultiAddress.init("/quic-v1").tryGet()
        resolveTAddress(tAddress).mapIt(
          MultiAddress.init(it, IPPROTO_UDP).tryGet().concat(quicV1).tryGet()
        )
      else:
        resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())
    return ok(resolved)
  except CatchableError as exc:
    return err(exc.msg)

proc connectToBootstrap*(
    switch: Switch, muxer: string, service: string
): Future[Result[seq[(PeerId, seq[MultiAddress])], string]] {.async.} =
  ## Resolve the bootstrap service and dial it. We don't know the bootstrap's
  ## peer id up front, so dial with allowUnknownPeerId and learn it from the dial.
  var addrs: seq[MultiAddress] = @[]
  for attempt in 1 .. 20:
    addrs = (await resolveBootstrapAddrs(muxer, service)).valueOr:
      warn "Failed to resolve bootstrap service, retrying",
        service = service, attempt = attempt, error = error
      await sleepAsync(5.seconds)
      continue
    if addrs.len > 0:
      break
    await sleepAsync(5.seconds)

  if addrs.len == 0:
    return err("Could not resolve bootstrap service: " & service)

  var
    bootstraps: seq[(PeerId, seq[MultiAddress])] = @[]
    lastErr = ""
  for address in addrs:
    var backoff = 1.seconds
    for attempt in 1 .. 10:
      try:
        let peerId = await switch.connect(address, allowUnknownPeerId = true).wait(
          BootstrapDialTimeout
        )
        notice "Connected to bootstrap", address = address, peerId = peerId
        bootstraps.add((peerId, @[address]))
        break
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        lastErr = exc.msg
        warn "Failed to connect to bootstrap, retrying",
          address = address, attempt = attempt, backoff = backoff, error = exc.msg
        await sleepAsync(backoff)
        backoff = min(backoff * 2, 30.seconds)

  if bootstraps.len == 0:
    return err(
      "Could not connect to any bootstrap (" & $addrs.len & " candidates): " & lastErr
    )
  ok(bootstraps)

proc mountKadDht*(switch: Switch, rng: Rng): KadDHT =
  ## Mount kad-dht *before* the switch starts; the switch then starts the protocol
  ## (no manual start). Bootstrap peers are seeded later via updatePeers once dialed.
  let kad = KadDHT.new(switch, rng = rng)
  switch.mount(kad)
  kad
