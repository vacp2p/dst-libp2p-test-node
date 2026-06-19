import strutils, os
import chronos
import chronicles
import env
import libp2p, libp2p/[crypto/crypto, crypto/secp, multiaddress]
import libp2p_mix
import ./helpers
import ./mix_ping

import sequtils, metrics, metrics/chronos_httpserver
from nativesockets import getHostname


proc resolveAddress(muxer: string, tAddress: string): Future[Result[seq[MultiAddress], string]] {.async.} =
  while true:
    try:
      let resolvedAddrs =
        if muxer.toLowerAscii() == "quic":
          let quicV1 = MultiAddress.init("/quic-v1").tryGet()
          resolveTAddress(tAddress).mapIt(
            MultiAddress.init(it, IPPROTO_UDP).tryGet()
              .concat(quicV1).tryGet()
          )
        else:
          resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())
      info "Address resolved", tAddress = tAddress, resolvedAddrs = resolvedAddrs
      return ok(resolvedAddrs)
    except CatchableError as exc:
      warn "Failed to resolve address, retrying", address = tAddress, error = exc.msg
      await sleepAsync(15.seconds)

proc connectPeers(
  switch: Switch, muxer: string, networkSize: int, myId: int, connectTo: int, rng: auto
): Future[Result[int, string]] {.async.} =
  var
    addrs: seq[MultiAddress]
    tAddresses: seq[string]
    connected = 0

  if localSmoke:
    var peers = toSeq(0..<networkSize).filterIt(it != myId)
    rng.shuffle(peers)
    #collect enough random peers to make target connections
    let peersAddrs = peers[0..<min(connectTo * 2, peers.len)].mapIt("pod-" & $it & ":" & $myPort)
    tAddresses = peersAddrs
  else:
    let serviceName = getEnv("SERVICE", "nimp2p-service")
    tAddresses = @[serviceName & ":" & $myPort]

  for tAddress in tAddresses:
    let resolvedAddrs = (await resolveAddress(muxer, tAddress)).valueOr:
      warn "Failed to resolve address", tAddress = tAddress, error = error
      continue
    addrs.add(resolvedAddrs)

  rng.shuffle(addrs)

  #Make target connections
  for peer in addrs:
    if connected > connectTo: break
    try:
      discard await switch.connect(peer, allowUnknownPeerId=true).wait(5.seconds)
      connected.inc()
      info "Connected!: current connections ", connected = $connected, target = connectTo
    except CatchableError as exc:
      warn "Failed to dial ", theirAddress = peer, message = exc.msg
      await sleepAsync(15.seconds)

  if connected == 0:
    return err("Failed to connect any peer")
  elif connected < connectTo:
    warn "Connected to fewer peers than target", connected = connected, target = connectTo
  return ok(connected)


proc main {.async.} =
  let
    rng = libp2p.newRng()
    (myId, networkSize, connectTo, muxer, filePath, address) = getPeerDetails().valueOr:
      error "Error reading peer settings ", err = error
      return
  let mixCfg = validateMixConfig()
  if mixCfg.isErr:
    error "Invalid mix config", err = mixCfg.error
    return

  # Resolve own hostname so MixPubInfo carries a dialable multiaddr.
  let myHostname = getHostname() & ":" & $myPort
  let myResolved = (await resolveAddress(muxer, myHostname)).valueOr:
    error "Failed to resolve own hostname", err = error
    return
  if myResolved.len == 0:
    error "No addresses for own hostname"
    return

  # generateRandom gives Curve25519 mix keys + secp256k1 libp2p keys; keep
  # both keypairs and substitute the resolved hostname as the multiaddr.
  let base = MixNodeInfo.generateRandom(myPort.int, rng)
  let mixNodeInfo = initMixNodeInfo(
    base.peerId, myResolved[0],
    base.mixPubKey, base.mixPrivKey,
    base.libp2pPubKey, base.libp2pPrivKey,
  )

  var builder = SwitchBuilder
    .new()
    .withNoise()
    .withAddress(MultiAddress.init(address).tryGet())
    .withMaxConnections(parseInt(getEnv("MAXCONNECTIONS", "250")))
    .withPrivateKey(PrivateKey(scheme: Secp256k1, skkey: mixNodeInfo.libp2pPrivKey))

  case muxer.toLowerAscii()
  of "quic":
    builder = builder.withQuicTransport()
  of "yamux":
    builder = builder.withTcpTransport(flags = {ServerFlags.TcpNoDelay})
              .withYamux()
  of "mplex":
    builder = builder.withTcpTransport(flags = {ServerFlags.TcpNoDelay})
              .withMplex()

  let switch = builder.build()

  let mixProto = MixProtocol.new(mixNodeInfo, switch)
  switch.mount(mixProto)

  let pingProto = mix_ping.setup(switch, mixProto, rng)

  # Publish own MixPubInfo so peers can read it after STARTSLEEP.
  let writeRes = writeMixPubInfoFile(toMixPubInfo(mixNodeInfo), myId, filePath)
  if writeRes.isErr:
    error "Failed to write own pubInfo file", err = writeRes.error
    return

  await switch.start()

  # Metrics
  info "Starting metrics server"
  let metricsServer = startMetricsServer(parseIpAddress("0.0.0.0"), prometheusPort)
  if metricsServer.isErr:
    error "Failed to initialize metrics server", err = metricsServer.error

  info "Listening on ", address = switch.peerInfo.addrs
  info "Peer details ", peer = myId, peerId = switch.peerInfo.peerId
  await sleepAsync(start_sleep.seconds)

  # Poll for peer files in case slow peers are still booting.
  const PubInfoPollAttempts = 60   # up to 60s of additional wait at 1s/iter
  var pubInfos: seq[MixPubInfo]
  for _ in 0 ..< PubInfoPollAttempts:
    pubInfos.setLen(0)
    for i in 0 ..< numMix:
      if i == myId: continue
      let infoRes = readMixPubInfoFile(i, filePath)
      if infoRes.isOk:
        pubInfos.add(infoRes.get())
    if pubInfos.len == numMix - 1: break
    await sleepAsync(1.seconds)
  if pubInfos.len < numMix - 1:
    warn "Mix nodePool incomplete after polling", got = pubInfos.len, expected = numMix - 1
  mixProto.nodePool.add(pubInfos)
  info "Mix nodePool populated", count = pubInfos.len

  asyncSpawn mix_ping.periodicMixPing(mixProto, pingProto)

  discard (await connectPeers(switch, muxer, networkSize, myId, connectTo, rng)).valueOr:
    error "Failed to establish any connections", error = error
    return

  await sleepAsync(2.days)

waitFor(main())
