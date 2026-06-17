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
  KadWarmupRounds = 3            # extra FIND_NODE rounds after the initial bootstrap
  KadWarmupSleep  = 2.seconds
  KadRefreshInterval = 60.seconds  # steady-state table refresh (also keeps links warm)
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

proc mountKadDht*(
    switch: Switch, rng: Rng, bootstraps: seq[(PeerId, seq[MultiAddress])]
): Future[KadDHT] {.async.} =
  ## Build the DHT seeded with the bootstrap nodes, start it (which performs the
  ## initial table bootstrap), then mount so we answer incoming queries. The
  ## switch is already running, so the protocol must be started before mounting
  ## (Switch.mount raises "Protocol not started" otherwise).
  let kad = KadDHT.new(switch, bootstrapNodes = bootstraps, rng = rng)
  await kad.start()
  switch.mount(kad)
  return kad

proc kadWarmup*(kad: KadDHT, rounds = KadWarmupRounds) {.async.} =
  ## A few extra refresh rounds widen the set of discovered/connected peers so
  ## GossipSub has enough candidates to fill its mesh (dHigh).
  for i in 1 .. rounds:
    try:
      await kad.bootstrap(forceRefresh = true)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "kad warmup round failed", round = i, error = exc.msg
    info "kad warmup round done", round = i
    await sleepAsync(KadWarmupSleep)

proc kadRefreshLoop*(kad: KadDHT, interval = KadRefreshInterval) {.async.} =
  ## Steady-state table refresh. Keeps the routing table current and the
  ## bootstrap/mesh links warm during the deployment phase.
  while true:
    await sleepAsync(interval)
    try:
      await kad.bootstrap(forceRefresh = false)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "kad refresh failed", error = exc.msg
