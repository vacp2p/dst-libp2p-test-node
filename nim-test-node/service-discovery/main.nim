import chronos, chronicles
import std/sequtils
import libp2p, libp2p/[multiaddress]
import libp2p/extended_peer_record
import env, helpers, core

proc main() {.async.} =
  let cfg = getNodeConfig().valueOr:
    error "Invalid node configuration", error
    quit(1)

  var switch = buildSwitch(cfg.muxer, cfg.listenAddress)
  await switch.start()

  let selfId = switch.peerInfo.peerId
  notice "Service discovery node started",
    peerId = $selfId,
    role = cfg.role,
    listen = cfg.listenAddress

  var bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[]
  if cfg.role != RoleBootstrap:
    if cfg.startupJitterMs > 0:
      notice "Applying startup jitter", delayMs = cfg.startupJitterMs
      await sleepAsync(cfg.startupJitterMs.milliseconds)

    let connectedBootstraps = await connectToBootstraps(
      switch,
      cfg.muxer,
      cfg.bootstrapService,
      cfg.listenPort,
    )
    bootstrapNodes = connectedBootstraps.valueOr:
      error "Failed to connect to bootstrap nodes", service = cfg.bootstrapService, error
      quit(1)

  let disco = await mountServiceDiscovery(
    switch,
    bootstrapNodes,
    cfg.safetyParam,
    cfg.ipSimCoefficient,
    cfg.advertExpiry,
    cfg.xprPublishing,
  )

  discard await startHealthServer(cfg.healthPort)

  let advertisedServices = cfg.advertiseServices.mapIt(
    ServiceInfo(id: it, data: cfg.serviceData)
  )

  case cfg.role
  of RoleBootstrap:
    notice "Bootstrap role active"
    while true:
      await sleepAsync(1.hours)
  of RoleAdvertiser:
    disco.startAdvertisingServices(advertisedServices)
    while true:
      await sleepAsync(1.hours)
  of RoleDiscoverer:
    disco.startDiscoveringServicesLog(cfg.discoverServices)
    await disco.runLookupLoop(cfg.discoverServices, cfg.lookupInterval)
  of RoleHybrid:
    disco.startAdvertisingServices(advertisedServices)
    disco.startDiscoveringServicesLog(cfg.discoverServices)
    await disco.runLookupLoop(cfg.discoverServices, cfg.lookupInterval)

waitFor(main())
