import libp2p
import chronos, chronos/apps/http/httpserver
import chronicles
import libp2p/protocols/[kademlia, kad_disco]
import os
import env

# --- Helpers ---

proc getRandomPeerId*(): PeerId =
  # Generates a random peer ID for FIND_NODE targets
  let rng = newRng()
  return PeerId.init(PrivateKey.random(Secp256k1, rng[]).get()).get()

proc buildSwitch*(muxer: string, address: string): Switch =
  var builder = SwitchBuilder
      .new()
      .withNoise()
      .withRng(crypto.newRng())
      .withAddresses(@[MultiAddress.init(address).tryGet()])
      .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
      .withMaxConnections(200)

  case muxer.toLowerAscii()
  of "quic":
    builder = builder.withQuicTransport()
  of "yamux":
    builder = builder.withTcpTransport(flags = {ServerFlags.TcpNoDelay})
              .withYamux()
  of "mplex":
    builder = builder.withTcpTransport(flags = {ServerFlags.TcpNoDelay})
              .withMplex()

  builder.build()

proc mountDiscovery*(switch: Switch, discovery: string, addresses: seq[(PeerId, seq[MultiAddress])]
  ): Future[KadDHT] {.async.}  =
  # Discovery selection
  if discovery == "kad-dht":
    let kad = KadDHT.new(
      switch,
      bootstrapNodes = addresses,
      config = KadDHTConfig.new(),
    )
    await kad.start()
    switch.mount(kad)
    return kad

  if discovery == "extended":
    let disco = KademliaDiscovery.new(
      switch,
      bootstrapNodes = addresses,
      config = KadDHTConfig.new(), # TODO check if this config is valid?
    )
    await disco.start()
    switch.mount(disco)
    return disco

  raise newException(ValueError, "Unknown DISCOVERY: " & discovery)


proc connectToBootstraps*(switch: Switch, muxer: string, service: string
  ): Future[Result[seq[(PeerId, seq[MultiAddress])], string]] {.async.} =
  let addrsRes = await resolveService(muxer, service)
  let addrs = addrsRes.valueOr:
    return err("Failed to resolve bootstrap service '" & service & "': " & error)
  info "Service resolved", service = addrs

  var bootstraps: seq[(PeerId, seq[MultiAddress])] = @[]
  var lastErr = ""

  for addr in addrs:
    var backoff = 1.seconds
    for attempt in 1..10:
      try:
        let remotePeerId: PeerId = await switch.connect(addr, allowUnknownPeerId = true).wait(10.seconds)
        notice "Connected to bootstrap", address = addr, peerId = remotePeerId
        bootstraps.add((remotePeerId, @[addr]))
        break
      except CatchableError as exc:
        lastErr = exc.msg
        warn "Failed to connect to bootstrap, retrying",
          address = addr, attempt = attempt, backoff = backoff, error = exc.msg
        await sleepAsync(backoff)
        backoff = min(backoff * 2, 30.seconds)

  if bootstraps.len == 0:
    return err("Could not connect to any bootstrap resolved from '" & service &
               "' (candidates=" & $addrs.len & "). Last error: " & lastErr)

  ok(bootstraps)


proc startHealthServer*(port: Port): Future[HttpServerRef] {.async.} =
  proc handler(request: RequestFence): Future[HttpResponseRef] {.async.} =
    if request.isErr():
      return defaultResponse()

    let req = request.get()

    if req.meth == MethodGet and (req.uri.path == "/health" or req.uri.path == "/ready"):
      return await req.respond(
        Http200,
        "ok",
        HttpTable.init([("Content-Type", "text/plain")])
      )

    return await req.respond(Http404, "Not Found")

  let addrs = initTAddress("0.0.0.0:" & $port)
  let serverRes = HttpServerRef.new(addrs, handler)
  if serverRes.isErr():
    raise newException(CatchableError, "Failed to create health HTTP server: " & $serverRes.error)

  let server = serverRes.get()
  server.start()
  return server