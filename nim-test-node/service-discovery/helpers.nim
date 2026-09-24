import strutils, sequtils
import chronos
import chronicles
import libp2p, libp2p/[multiaddress]
import libp2p/protocols/[kademlia, service_discovery]

logScope:
  topics = "dst"

proc buildSwitch*(muxer: string, max_connections: int, listenAddress: string): Switch =
  var builder = SwitchBuilder
    .new()
    .withNoise()
    .withRng(libp2p.newRng())
    .withAddresses(@[MultiAddress.init(listenAddress).tryGet()])
    .withMaxConnections(max_connections)

  case muxer
  of "quic":
    builder = builder.withQuicTransport()
  of "yamux":
    builder = builder.withTcpTransport(flags = {ServerFlags.TcpNoDelay}).withYamux()
  of "mplex":
    builder = builder.withTcpTransport(flags = {ServerFlags.TcpNoDelay}).withMplex()
  else:
    raiseAssert "invalid muxer, validated in config parser"

  builder.build()

proc resolveAddress(
    muxer: string, targetAddress: string
): Future[Result[seq[MultiAddress], string]] {.async.} =
  while true:
    try:
      let resolvedAddrs =
        if muxer == "quic":
          let quicV1 = MultiAddress.init("/quic-v1").tryGet()
          resolveTAddress(targetAddress).mapIt(
            MultiAddress.init(it, IPPROTO_UDP).tryGet().concat(quicV1).tryGet()
          )
        else:
          resolveTAddress(targetAddress).mapIt(MultiAddress.init(it).tryGet())
      info "Address resolved", targetAddress, resolvedAddrs
      return ok(resolvedAddrs)
    except CatchableError as exc:
      warn "Failed to resolve address", targetAddress, error = exc.msg
      await sleepAsync(15.seconds)

proc resolveService*(
    muxer: string, service: string, defaultPort: Port
): Future[Result[seq[MultiAddress], string]] {.async.} =
  let targetAddress =
    if ":" in service:
      service
    else:
      service & ":" & $defaultPort

  let resolvedAddrs = (await resolveAddress(muxer, targetAddress)).valueOr:
    return err("Failed to resolve address " & targetAddress & ": " & error)

  var addrs = resolvedAddrs
  if addrs.len > 0:
    let rng = libp2p.newRng()
    rng.shuffle(addrs)

  ok(addrs)

proc connectToBootstraps*(
    switch: Switch,
    muxer: string,
    service: string,
    defaultPort: Port,
    maxConnections: int,
): Future[Result[seq[(PeerId, seq[MultiAddress])], string]] {.async.} =
  if maxConnections <= 0:
    return err("maxConnections must be greater than 0")

  let addrsRes = await resolveService(muxer, service, defaultPort)
  let addrs = addrsRes.valueOr:
    return err("Failed to resolve bootstrap service '" & service & "': " & error)

  var bootstraps: seq[(PeerId, seq[MultiAddress])] = @[]
  var lastErr = ""

  for addr in addrs:
    if bootstraps.len >= maxConnections:
      break

    var backoff = 1.seconds
    for attempt in 1 .. 10:
      try:
        let peerId =
          await switch.connect(addr, allowUnknownPeerId = true).wait(10.seconds)
        info "Connected to bootstrap", address = addr, peerId, attempt
        bootstraps.add((peerId, @[addr]))
        break
      except CatchableError as exc:
        lastErr = exc.msg
        warn "Failed to connect bootstrap, retrying",
          address = addr, attempt, backoff, error = exc.msg
        await sleepAsync(backoff)
        backoff = min(backoff * 2, 30.seconds)

  if bootstraps.len == 0:
    return err(
      "Could not connect to any bootstrap resolved from '" & service & "' (candidates=" &
        $addrs.len & "). Last error: " & lastErr
    )

  ok(bootstraps)

proc mountServiceDiscovery*(
    switch: Switch,
    safetyParam: float64,
    ipSimCoefficient: float64,
    advertExpiry: Duration,
    xprPublishing: bool,
): ServiceDiscovery =
  let kadCfg =
    KadDHTConfig.new(validator = ExtEntryValidator(), selector = ExtEntrySelector())

  let discoCfg = ServiceDiscoveryConfig.new(
    safetyParam = safetyParam,
    ipSimCoefficient = ipSimCoefficient,
    advertExpiry = advertExpiry,
  )

  let disco = ServiceDiscovery.new(
    switch,
    bootstrapNodes = @[],
    config = kadCfg,
    rng = libp2p.newRng(),
    codec = ExtendedServiceDiscoveryCodec,
    discoConfig = discoCfg,
    xprPublishing = xprPublishing,
  )

  switch.mount(disco)
  disco
