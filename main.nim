import stew/endians2, stew/byteutils, tables, strutils, os, json
import chronos, chronos/apps/http/httpserver
import mix_helpers, env
import std/[strformat, random, hashes]
import mix/mix_protocol
import libp2p, libp2p/[muxers/mplex/lpchannel, crypto/secp, multiaddress]
import libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]

import sequtils, math, metrics, metrics/chronos_httpserver
from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname


proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  return ok(($m.data.hash).toBytes())

proc createMessageHandler(): proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
  var messagesChunks: CountTable[uint64]

  return proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
    let sentUint = uint64.fromBytesLE(data)
    # warm-up
    if sentUint < 1000000: return

    messagesChunks.inc(sentUint)
    if messagesChunks[sentUint] < chunks: return
    let
      sentMoment = nanoseconds(int64(uint64.fromBytesLE(data)))
      sentNanosecs = nanoseconds(sentMoment - seconds(sentMoment.seconds))
      sentDate = initTime(sentMoment.seconds, sentNanosecs)
      diff = getTime() - sentDate
    echo sentUint, " milliseconds: ", diff.inMilliseconds()

proc messageValidator(topic: string, msg: Message): Future[ValidationResult] {.async.} =
  return ValidationResult.Accept


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

proc initializeGossipsub(switch: Switch, anonymize: bool, mixProto: Option[MixProtocol] = none(MixProtocol)): GossipSub =
  return GossipSub.init(
      switch = switch,
      triggerSelf = parseBool(getEnv("SELFTRIGGER", "true")),
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = anonymize,
      customConnCallbacks = if isMix and mixProto.isSome:
        #add custom connection and peer selection callbacks for mix
        some(CustomConnectionCallbacks(
          customConnCreationCB: makeMixConnCb(mixProto.get()),
          customPeerSelectionCB: makeMixPeerSelectCb()
        ))
      else:
        none(CustomConnectionCallbacks)
    )

proc configureGossipsubParams(gossipSub: GossipSub) =
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

proc subscribGossipsubTopic(gossipSub: GossipSub, topic: string) =
  gossipSub.topicParams[topic] = TopicParams(
    topicWeight: 1,
    firstMessageDeliveriesWeight: 1,
    firstMessageDeliveriesCap: 30,
    firstMessageDeliveriesDecay: 0.9
  )

  gossipSub.subscribe(topic, createMessageHandler())
  gossipSub.addValidator([topic], messageValidator)


proc connetGossipsubPeers(
    switch: Switch, peersInfo: seq[int], muxer: string, connectTo: int
): Future[Result[int, string]] {.async.} =
  var connected = 0
  for peerInfo in peersInfo:
    if connected > connectTo: break

    let tAddress = if inShadow:
        "pod-" & $peerInfo & ":" & $myPort                        # Shadow format
    else:
        "pod-" & $peerInfo & ".nimp2p-service:" & $myPort         # k8s format

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
      info "Connected!: current connections ", connected = $connected, target = connectTo
    except CatchableError as exc:
      info "Failed to dial ", theirAddress = tAddress, message = exc.msg
      await sleepAsync(15.seconds)
  if connected == 0:
    return err("Failed to connect any peer")
  elif connected < connected:
    info "Connected to fewer peers than target", connected = connected, target = connectTo
  return ok(connected)

proc main {.async.} =
  randomize()
  let
    rng = libp2p.newRng() 
    (myId, networkSize, connectTo, muxer, filePath, address) = getPeerDetails().valueOr:
      error "Error reading peer settings ",  err = error
      return
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
  if myId < mixCount:
    let mixProto = MixProtocol.new(myId, mixCount, switch, filePath).valueOr:
      error "Could not instantiate mix", err = error
      return

    gossipSub = initializeGossipsub(switch, true, some(mixProto))
    switch.mount(mixProto)
  else:
    gossipSub = initializeGossipsub(switch, true)

  configureGossipsubParams(gossipSub)
  subscribGossipsubTopic(gossipSub, "test")
  switch.mount(gossipSub)
  await switch.start()

  # Metrics
  info "Starting metrics server"
  let metricsServer = startMetricsServer(parseIpAddress("0.0.0.0"), prometheusPort)
  if metricsServer.isErr:
    error "Failed to initialize metrics server", err = metricsServer.error
  elif inShadow:
    asyncSpawn storeMetrics(myId)

  info "Listening on ", address = switch.peerInfo.addrs
  info "Peer details ", peer = myId, peerId = switch.peerInfo.peerId
  #Wait for node building
  await sleepAsync(60.seconds)

  #connect with peers
  var peersInfo = toSeq(0..<networkSize).filterIt(it != myId)
  rng.shuffle(peersInfo)
  discard (await connetGossipsubPeers(switch, peersInfo, muxer, connectTo)).valueOr:
    error "Failed to establish any connections", error = error 
    return
  await sleepAsync(5.seconds)
  info "Mesh size ", mesh = gossipSub.mesh.getOrDefault("test").len

  info "Starting listening endpoint for publish controller"
  discard gossipSub.startHttpServer(myId)

  while true:
    await sleepAsync(2.days)

waitFor(main())