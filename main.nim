import stew/endians2, stew/byteutils, tables, strutils, os, osproc, json
import chronos, chronos/apps/http/httpserver
import node
import std/[strformat, random, hashes]
import mix/[mix_node, entry_connection, mix_protocol]

import libp2p, libp2p/protocols/pubsub/rpc/messages
import libp2p/muxers/mplex/lpchannel, libp2p/protocols/ping
import libp2p/crypto/secp, libp2p/protocols/pubsub/pubsubpeer

import sequtils, math, metrics, metrics/chronos_httpserver
from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname

let
  #Env(ISMIX) to enable mix support. First mixCount peers are mix-net peers
  isMix = existsEnv("ISMIX")
  mixCount = parseInt(getEnv("NUMMIX", "0"))
  inShadow = existsEnv("SHADOWENV")
  httpPublishPort = Port(8645)            #http message injector
  prometheusPort = Port(8008)
  myPort = Port(5000)
  chunks = parseInt(getEnv("FRAGMENTS", "1"))

proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  return ok(($m.data.hash).toBytes())

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): Result[MetricsHttpServerRef, string] =
  info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $serverPort

  let metricsServerRes = MetricsHttpServerRef.new($serverIp, serverPort)
  if metricsServerRes.isErr():
    return err("metrics HTTP server start failed: " & $metricsServerRes.error)

  let server = metricsServerRes.value
  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort
  ok(metricsServerRes.value)

# log metrics if needed (useful for shadow simulations)
proc storeMetrics(myId: int) {.async.} =
  await sleepAsync((myId*60).milliseconds)
  while true:
    try:
      let cmd = "curl -s --connect-timeout 5 --max-time 5 http://localhost:" & 
          $prometheusPort & "/metrics >> metrics_pod-" & $myId & ".txt"
      
      let exitCode = execCmd(cmd)
      if exitCode == 0:
        info "Metrics saved for peer ", pod = myId
      else:
        info "Failed to fetch metrics for peer ", pod = myId, curlExitCode = $exitCode
    except CatchableError as e:
      info "Error storing metrics: ", error = e.msg
    await sleepAsync(60.seconds)

proc publishNewMessage(gossipSub: GossipSub, msgSize: int, topic: string): Future[(Time, int)] {.async.} =
  let
    now = getTime()
    nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
  var 
    res = 0
    #create payload with timestamp, so the receiver can discover elapsed time
    nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](msgSize div chunks)

  #To support message fragmentation, we add fragment #. Each fragment (chunk) differs by one byte
  for chunk in 0..<chunks:
    nowBytes[10] = byte(chunk)
    res = if isMix:
      await gossipSub.publish(topic, nowBytes, 
        publishParams = some(PublishParams(skipMCache: true, useCustomConn: isMix)),
      )
    else:
      await gossipSub.publish(topic, nowBytes)
  return (now, res)

#http endpoint for detached controller
proc startHttpServer(gossipSub: GossipSub, myId: int): Future[HttpServerRef] {.async.} =
  #Look for incoming requests from publish controller
  proc processRequests(request: RequestFence): Future[HttpResponseRef] {.async.} =
    if request.isErr():
      return defaultResponse()
      
    let req = request.get()
    try:
      case req.meth
      of MethodPost:
        if req.uri.path == "/publish":
          let
            bodyBytes = await req.getBody()
            jsonBody = parseJson(string.fromBytes(bodyBytes))
            topic = jsonBody["topic"].getStr()
            msgSize = jsonBody["msgSize"].getInt()
            version = jsonBody["version"].getInt()     #check for compatible version?

          info "controller message ", command = req.uri.path, topic = topic, size = msgSize, version = version
          let (publishTime, publishResult) = await gossipSub.publishNewMessage(msgSize, topic)
          
          if publishResult > 0:
            let responseJson = """{"status":"success","message":"Message published at time """ & $publishTime & "}"
            return await req.respond(Http200, responseJson, HttpTable.init([("Content-Type", "application/json")]))
          else:
            let responseJson = """{"status":"error","message":"Failed to publist at time """ & $publishTime & "}"
            return await req.respond(Http500, responseJson, HttpTable.init([("Content-Type", "application/json")]))
        else:
          return await req.respond(Http404, "Not Found")          
      else:
        return await req.respond(Http405, "Method Not Supported")
        
    except CatchableError as e:
      info "Error handling http request: ", error = e.msg
      let responseJson = """{"status":"error","message":"""" & e.msg.replace("\"", "\\\"") & """"}"""
      return await req.respond(Http400, responseJson, HttpTable.init([("Content-Type", "application/json")]))

  # http endpoint for publish controller
  info "starting http server", httpPort = $httpPublishPort
  let serverAddress = initTAddress("0.0.0.0:" & $httpPublishPort)
  let serverRes = HttpServerRef.new(serverAddress, processRequests)

  if serverRes.isErr():
    raise newException(CatchableError, "Failed to create HTTP server: " & $serverRes.error)
    
  let server = serverRes.get()
  server.start()
  info "http server started ", httpPort = $httpPublishPort
  return server

var mixNodes: MixNodes = @[]
const mix_D* = 4 # No. of peers to forward to

proc mixPeerSelection*(
    allPeers: HashSet[PubSubPeer],
    directPeers: HashSet[PubSubPeer],
    meshPeers: HashSet[PubSubPeer],
    fanoutPeers: HashSet[PubSubPeer],
): HashSet[PubSubPeer] {.gcsafe, raises: [].} =
  var
    peers: HashSet[PubSubPeer]
    allPeersSeq = allPeers.toSeq()
  let rng = newRng()
  rng.shuffle(allPeersSeq)
  for p in allPeersSeq:
    peers.incl(p)
    if peers.len >= mix_D:
      break
  return peers


proc initializeMix(myId: int, mixCount: int): 
  Result[(MultiAddress, SkPublicKey, SkPrivateKey), string] =
  {.gcsafe.}:
    #We assume that first mixCount nodes are mix capable nodes
    let (multiAddrStr, libp2pPubKey, libp2pPrivKey) =
      if myId < mixCount:
        mixNodes = initializeMixNodes(1, int(myPort)).valueOr:
          return err("Could not generate Mix nodes")
        let (ma, _, _, pubKey, privKey) = getMixNodeInfo(mixNodes[0])
        (ma, pubKey, privKey)  
      else:
        discard initializeNodes(1, int(myPort))
        getNodeInfo(nodes[0])
    
    let 
      multiAddrParts = multiAddrStr.split("/p2p/")
      multiAddr = MultiAddress.init(multiAddrParts[0]).valueOr:
        return err("Failed to initialize MultiAddress for Mix")
    
    ok((multiAddr, libp2pPubKey, libp2pPrivKey))


proc writeMixInfoFiles(switch: Switch, myId: int, mixCount: int, publicKey: SkPublicKey, filePath: string) =
  {.gcsafe.}:
    var externalAddr: string = ""
    let addresses = getInterfaces().filterIt(it.name == "eth0").mapIt(it.addresses)
    if addresses.len < 1 or addresses[0].len < 1:
      if inShadow and fileExists("/etc/hosts"):
        let
          content = readFile("/etc/hosts")
          hostname = gethostname()
        for line in content.splitLines():
          if line.contains(hostname) and not line.startsWith("#"):
            let
              parts = line.strip().split()
              ip = parts[0]
            if not (ip.startsWith("127") or ip.contains("::1")):
                externalAddr = ip
                break
    else:        
      externalAddr = ($addresses[0][0].host).split(":")[0]
    
    if externalAddr == "":
      info "Can't find external IP address", peer = myId
      return

    let
      peerId = switch.peerInfo.peerId
      externalMultiAddr = fmt"/ip4/{externalAddr}/tcp/{myPort}/p2p/{peerId}"

    if myId < mixCount: #or we need to do for entire network if isMix ??
      discard mixNodes.initMixMultiAddrByIndex(0, externalMultiAddr)
      writeMixNodeInfoToFile(mixNodes[0], myId, filePath / fmt"nodeInfo").isOkOr:
        error "Failed to write mix info to file", nodeId = myId, err = error
        return

      let nodePubInfo = mixNodes.getMixPubInfoByIndex(0).valueOr:
        error "Get mix pub info by index error", nodeId = myId, err = error
        return
      writeMixPubInfoToFile(nodePubInfo, myId, filePath / fmt"pubInfo").isOkOr:
        error "Failed to write mix pub info to file", nodeId = myId, err = error
        return
    let pubInfo = initPubInfo(externalMultiAddr, publicKey)
    writePubInfoToFile(pubInfo, myId, filePath / fmt"libp2pPubInfo").isOkOr:
      error "Failed to write pub info to file", nodeId = myId, err = error
      return

    info "Successfully written mix info", peer = myId, address = externalMultiAddr

proc makeMixConnCb(mixProto: MixProtocol): CustomConnCreationProc =
  #customconn callback for MixEntryConnection
  return proc(
      destAddr: Option[MultiAddress], destPeerId: PeerId, codec: string
  ): Connection {.gcsafe, raises: [].} =
    try:
      let dest = destAddr.valueOr:
        error "No destination address available for MixEntryConnection", destPeer = destPeerId
        return nil
      return mixProto.toConnection(MixDestination.init(destPeerId, dest), codec).get()
    except CatchableError as e:
      error "Error during execution of MixEntryConnection callback: ", err = e.msg
      return nil


proc main {.async.} =
  randomize()
  let
    hostname = getHostname()
    myId = parseInt(hostname.split('-')[^1])
    networkSize = parseInt(getEnv("PEERS", "1000"))
    connectTo = parseInt(getEnv("CONNECTTO", "10"))
    muxer = getEnv("MUXER", "yamux")
    isAttacker = false
    rng = libp2p.newRng()
    filePath = if inShadow: "../" else: getEnv("FILEPATH", "./")
    address = if muxer.toLowerAscii() == "quic":
      "/ip4/0.0.0.0/udp/" & $myPort & "/quic-v1"
    else: 
      "/ip4/0.0.0.0/tcp/" & $myPort

  if muxer.toLowerAscii() notin ["quic", "yamux", "mplex"]:
    error "Unknown muxer type", muxer = muxer
    return

  info "Host info ", host = hostname, peer = myId, muxer = muxer, mix = isMix, address = address

  var
    gossipSub: GossipSub
    mixPublicKey: SkPublicKey
    mixPrivKey: SkPrivateKey
    builder = SwitchBuilder
      .new()
      .withNoise()
      .withAddress(MultiAddress.init(address).tryGet())
      .withMaxConnections(parseInt(getEnv("MAXCONNECTIONS", "250")))

  if isMix:
    (_, mixPublicKey, mixPrivKey) = initializeMix(myId, mixCount).valueOr:
      error "Failed to initialize mix", err = error
      return
    #mix protocol uses same address as yamux
    builder = builder.withRng(crypto.newRng())
              .withPrivateKey(PrivateKey(scheme: Secp256k1, skkey: mixPrivKey))
  else:
    builder = builder.withRng(rng)

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

  if isMix:
    writeMixInfoFiles(switch, myId, mixCount, mixPublicKey, filePath)
    await sleepAsync(10.seconds)
    let mixProto = MixProtocol.new(myId, mixCount, switch, filePath).valueOr:
      error "Could not instantiate mix", err = error
      return

    let 
      mixConn = makeMixConnCb(mixProto)
      mixPeerSelect = proc(
        allPeers: HashSet[PubSubPeer],
        directPeers: HashSet[PubSubPeer],
        meshPeers: HashSet[PubSubPeer],
        fanoutPeers: HashSet[PubSubPeer],
      ): HashSet[PubSubPeer] {.gcsafe, raises: [].} =
        try:
          return mixPeerSelection(allPeers, directPeers, meshPeers, fanoutPeers)
        except CatchableError as e:
          error "Error during execution of MixPeerSelection callback: ", err = e.msg
          return initHashSet[PubSubPeer]()
    
    gossipSub = GossipSub.init(
      switch = switch,
      triggerSelf = parseBool(getEnv("SELFTRIGGER", "true")),
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
      customConnCallbacks = some(
        CustomConnectionCallbacks(
          customConnCreationCB: mixConn, customPeerSelectionCB: mixPeerSelect
        )
      ),
    )

    switch.mount(mixProto)
  
  else:
    gossipSub = GossipSub.init(
      switch = switch,
      triggerSelf = parseBool(getEnv("SELFTRIGGER", "true")),
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
    )

  # Metrics
  info "Starting metrics server"
  let metricsServer = startMetricsServer(parseIpAddress("0.0.0.0"), prometheusPort)
  if metricsServer.isErr:
    error "Failed to initialize metrics server", err = metricsServer.error
  elif inShadow:
    asyncSpawn storeMetrics(myId)

  gossipSub.parameters.floodPublish = true
  gossipSub.parameters.opportunisticGraftThreshold = -10000
  gossipSub.parameters.heartbeatInterval = 1.seconds
  gossipSub.parameters.pruneBackoff = 60.seconds
  gossipSub.parameters.gossipFactor = 0.25
  gossipSub.parameters.d = 6
  gossipSub.parameters.dLow = 4
  gossipSub.parameters.dHigh = 8
  gossipSub.parameters.dScore = 6
  gossipSub.parameters.dOut = 6 div 2
  gossipSub.parameters.dLazy = 6
  gossipSub.topicParams["test"] = TopicParams(
    topicWeight: 1,
    firstMessageDeliveriesWeight: 1,
    firstMessageDeliveriesCap: 30,
    firstMessageDeliveriesDecay: 0.9
  )

  var messagesChunks: CountTable[uint64]
  proc messageHandler(topic: string, data: seq[byte]) {.async.} =
    let sentUint = uint64.fromBytesLE(data)
    # warm-up
    if sentUint < 1000000: return
    #if isAttacker: return

    messagesChunks.inc(sentUint)
    if messagesChunks[sentUint] < chunks: return
    let
      sentMoment = nanoseconds(int64(uint64.fromBytesLE(data)))
      sentNanosecs = nanoseconds(sentMoment - seconds(sentMoment.seconds))
      sentDate = initTime(sentMoment.seconds, sentNanosecs)
      diff = getTime() - sentDate
    echo sentUint, " milliseconds: ", diff.inMilliseconds()

  var
    startOfTest: Moment
    attackAfter = 10000.hours
  proc messageValidator(topic: string, msg: Message): Future[ValidationResult] {.async.} =
    if isAttacker and Moment.now - startOfTest >= attackAfter:
      return ValidationResult.Ignore

    return ValidationResult.Accept

  gossipSub.subscribe("test", messageHandler)
  gossipSub.addValidator(["test"], messageValidator)
  switch.mount(gossipSub)
  await switch.start()

  info "Listening on ", address = switch.peerInfo.addrs
  info "Peer details ", peer = myId, peerId = switch.peerInfo.peerId
  #Wait for node building
  await sleepAsync(60.seconds)

  var 
    connected = 0
    peersInfo = toSeq(0..<networkSize).filterIt(it != myId)
  rng.shuffle(peersInfo)

  for peerInfo in peersInfo:
    if connected > connectTo: break
#[
    #Discuss: Not needed!
    if isMix:
      let pubInfo = readPubInfoFromFile(peerInfo, filePath / fmt"libp2pPubInfo").expect(
        "should be able to read pubinfo"
      )
      let (multiAddr, _) = getPubInfo(pubInfo)
      let ma = MultiAddress.init(multiAddr).expect("should be a multiaddr")
      info "Retrieved multiaddress", peer = peerInfo, multiAddr = ma

      try:
        let peerId = await switch.connect(ma, allowUnknownPeerId = true).wait(5.seconds)
        connected.inc()
      except CatchableError as exc:
        error "Failed to dial", err = exc.msg
        info "Waiting 15 seconds..."
        await sleepAsync(15.seconds)
      continue
]#

    let tAddress = if inShadow:
        "pod-" & $peerInfo & ":" & $myPort                        # Shadow format
    else:
        "pod-" & $peerInfo & ".nimp2p-service:" & $myPort         # k8s format

    info "Trying to resolve ", theirAddress = tAddress
    
    try:
      let addrs = 
        if muxer.toLowerAscii() == "quic":
          let quicV1 = MultiAddress.init("/quic-v1").tryGet()
          resolveTAddress(tAddress).mapIt(
            MultiAddress.init(it, IPPROTO_UDP).tryGet()
              .concat(quicV1).tryGet()
          )
        else:
          resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())

      info "Address resolved ", theirAddress = tAddress, resolved = addrs
      let peerId = await switch.connect(addrs[0], allowUnknownPeerId=true).wait(5.seconds)
      connected.inc()
      info "Connected!: current connections ", connected = $connected, desired = connectTo
    except CatchableError as exc:
      info "Failed to dial ", theirAddress = tAddress, message = exc.msg
      await sleepAsync(15.seconds)
  info "Mesh size ", mesh = gossipSub.mesh.getOrDefault("test").len
  
  await sleepAsync(5.seconds)
  info "Starting listening endpoint for publish controller"
  discard gossipSub.startHttpServer(myId)

  while true:
    await sleepAsync(1.hours)

  quit(0)

waitFor(main())