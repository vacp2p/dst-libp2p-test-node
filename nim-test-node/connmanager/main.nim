import sequtils
import chronos, chronicles
import metrics, metrics/chronos_httpserver
import libp2p, libp2p/[multiaddress, crypto/secp]
import env

logScope:
  topics = "connmanager-test"

proc resolveAndConnect(switch: Switch, address: string): Future[void] {.async.} =
  var backoff = 1.seconds
  for attempt in 1..10:
    try:
      let addrs = resolveTAddress(address).mapIt(MultiAddress.init(it).tryGet())
      if addrs.len == 0:
        raise newException(CatchableError, "no addresses resolved for " & address)
      let peerId = await switch.connect(addrs[0], allowUnknownPeerId = true).wait(10.seconds)
      notice "Connected", address = address, peerId = peerId
      return
    except CatchableError as exc:
      warn "Connection failed, retrying",
        address = address, attempt = attempt, backoff = backoff, error = exc.msg
      await sleepAsync(backoff)
      backoff = min(backoff * 2, 30.seconds)
  warn "Gave up connecting", address = address

proc startMetrics() =
  let res = MetricsHttpServerRef.new("0.0.0.0", prometheusPort)
  if res.isErr():
    warn "Failed to start metrics server", error = $res.error
    return
  let srv = res.get()
  try: waitFor srv.start()
  except CatchableError as exc:
    warn "Metrics server start failed", error = exc.msg

proc runHub(cfg: HubConfig) {.async.} =
  var builder = SwitchBuilder
    .new()
    .withRng(crypto.newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/" & $myPort).tryGet()])
    .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
    .withNoise()
    .withYamux()
    .withWatermark(
      cfg.lowWater,
      cfg.highWater,
      cfg.gracePeriodS.seconds,
      cfg.silencePeriodS.seconds,
    )

  if cfg.maxConnections > 0:
    builder = builder.withMaxConnections(cfg.maxConnections)

  let switch = builder.build()
  await switch.start()

  for peerId in cfg.protectedPeers:
    switch.connManager.protect(peerId, "dst-protected")

  notice "Hub started",
    peerId = switch.peerInfo.peerId,
    lowWater = cfg.lowWater,
    highWater = cfg.highWater,
    gracePeriodS = cfg.gracePeriodS,
    silencePeriodS = cfg.silencePeriodS,
    maxConnections = cfg.maxConnections,
    protectedPeers = cfg.protectedPeers.len,
    outboundPeers = cfg.outboundPeers.len

  startMetrics()

  for address in cfg.outboundPeers:
    asyncSpawn resolveAndConnect(switch, address)

  while true: await sleepAsync(1.hours)

proc runPeer(cfg: PeerConfig) {.async.} =
  var builder = SwitchBuilder
    .new()
    .withRng(crypto.newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/" & $myPort).tryGet()])
    .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
    .withNoise()
    .withYamux()

  if cfg.privateKey.isSome():
    builder = builder.withPrivateKey(cfg.privateKey.get())

  let switch = builder.build()
  await switch.start()

  notice "Peer started",
    peerId = switch.peerInfo.peerId,
    dialOut = cfg.dialOut,
    reconnect = $cfg.reconnect

  startMetrics()

  if cfg.dialOut:
    if cfg.reconnect == ReconnectAggressive:
      while true:
        # Reconnect to any hub we've lost. Check against expected hub count.
        if switch.connectedPeers(Direction.Out).len < cfg.hubAddrs.len:
          for addr in cfg.hubAddrs:
            asyncSpawn resolveAndConnect(switch, addr)
        await sleepAsync(1.seconds)
    elif cfg.reconnect == ReconnectBeforeGrace:
      # Cycle connections to all hubs before grace expires so the peer stays
      # perpetually within the grace window on every hub.
      while true:
        for addr in cfg.hubAddrs:
          await resolveAndConnect(switch, addr)
        await sleepAsync(cfg.reconnectIntervalS.seconds)
        for peerId in switch.connectedPeers(Direction.Out):
          try: await switch.disconnect(peerId)
          except CatchableError: discard
        notice "Cycled connection (grace abuse)", intervalS = cfg.reconnectIntervalS
    else:
      for addr in cfg.hubAddrs:
        await resolveAndConnect(switch, addr)
      while true: await sleepAsync(1.hours)
  else:
    while true: await sleepAsync(1.hours)

proc main() {.async.} =
  case getRole()
  of RoleHub: await runHub(parseHubConfig())
  of RolePeer: await runPeer(parsePeerConfig())

waitFor main()
