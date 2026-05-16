import stew/endians2, stew/byteutils, tables, strutils, os, json
import chronos, chronos/apps/http/httpserver
import env
import std/[strformat, random, hashes]
import libp2p, libp2p/[muxers/mplex/lpchannel, stream/connection, crypto/secp, multiaddress]
import libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]
# Mix protocol not available in this libp2p version
# import libp2p/protocols/[mix, mix/mix_protocol]

import sequtils, math, metrics, metrics/chronos_httpserver
from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from times import getTime, toUnixFloat, `-`, initTime, `$`, inMilliseconds, Time
from nativesockets import getHostname


template toUnixNanoseconds(t: times.Time): int64 =
  (t.toUnixFloat() * 1_000_000_000).int64

template fromUnixNanoseconds(ns: int64): times.Time =
  initTime(ns div 1_000_000_000, ns mod 1_000_000_000)

# Global variables for metric labels (set in main)
var
  gMuxer*: string = ""
  gPeerId*: string = ""

declareCounter(
  dst_testnode_publish_requests_total,
  "number of /publish requests accepted by the test node",
  labels = ["muxer", "peer_id"]
)

declareCounter(
  dst_testnode_publish_failures_total,
  "number of failed local publish attempts",
  labels = ["muxer", "peer_id"]
)

declareCounter(
  dst_testnode_received_chunks_total,
  "number of application-level message chunks received",
  labels = ["muxer", "peer_id"]
)

declareCounter(
  dst_testnode_completed_messages_total,
  "number of application-level messages fully received",
  labels = ["muxer", "peer_id"]
)

declareGauge(
  dst_testnode_last_message_delay_ms,
  "last observed application-level end-to-end message delay in milliseconds",
  labels = ["muxer", "peer_id"]
)

declareGauge(
  dst_testnode_mesh_size,
  "current GossipSub mesh size for the test topic",
  labels = ["muxer", "peer_id"]
)

declareGauge(
  dst_testnode_topic_peers,
  "current number of GossipSub peers for the test topic",
  labels = ["muxer", "peer_id"]
)
proc getEnvInt(name: string, defaultValue: int): int =
  let value = getEnv(name, "")
  if value.len == 0:
    return defaultValue

  try:
    return parseInt(value)
  except ValueError:
    warn "Invalid integer ENV value, using default",
      name = name,
      value = value,
      defaultValue = defaultValue
    return defaultValue


proc getEnvFloat(name: string, defaultValue: float): float =
  let value = getEnv(name, "")
  if value.len == 0:
    return defaultValue

  try:
    return parseFloat(value)
  except ValueError:
    warn "Invalid float ENV value, using default",
      name = name,
      value = value,
      defaultValue = defaultValue
    return defaultValue


proc getEnvBool(name: string, defaultValue: bool): bool =
  let value = getEnv(name, "")
  if value.len == 0:
    return defaultValue

  try:
    return parseBool(value)
  except ValueError:
    warn "Invalid bool ENV value, using default",
      name = name,
      value = value,
      defaultValue = defaultValue
    return defaultValue

proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  return ok(($m.data.hash).toBytes())

proc createMessageHandler(): proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
  var messagesChunks: CountTable[uint64]

  return proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
    let
      timestampNs = uint64.fromBytesLE(data[0 ..< 8]).int64
      sendTime = fromUnixNanoseconds(timestampNs)
      msgId = uint64.fromBytesLE(data[8 ..< 16])
      recvTime = getTime()
      delay = recvTime - sendTime

    # warm-up
    if timestampNs < 1000000: return

    # Log received message
    info "Received message",
      msgId = msgId,
      sentAt = timestampNs,
      current = recvTime.toUnixNanoseconds(),
      delayMs = delay.inMilliseconds()

    messagesChunks.inc(msgId)  # Use msgId instead of timestamp for tracking
    if messagesChunks[msgId] < chunks: return

    echo msgId, " milliseconds: ", delay.inMilliseconds()
    dst_testnode_completed_messages_total.inc(labelValues = [gMuxer, gPeerId])
    dst_testnode_last_message_delay_ms.set(delay.inMilliseconds().int64, labelValues = [gMuxer, gPeerId])

proc messageValidator(topic: string, msg: Message): Future[ValidationResult] {.async.} =
  return ValidationResult.Accept


proc publishNewMessage(gossipSub: GossipSub, msgSize: int, topic: string): Future[(Time, int)] {.async.} =
  dst_testnode_publish_requests_total.inc(labelValues = [gMuxer, gPeerId])
  let
    now = getTime()
    nowInt = now.toUnixFloat() * 1_000_000_000.0  # seconds + nanoseconds as float
    msgId = uint64(rand(high(int64)))  # Safe 0..<2^63 range

  var
    res = 0
    nowBytes = @(toBytesLE(uint64(nowInt))) & @(toBytesLE(msgId)) &
             newSeq[byte](msgSize div chunks - 16)

  info "Sent message",
    msgId = msgId,
    timestamp = getTime().toUnixNanoseconds()

  #To support message fragmentation, we add fragment #. Each fragment (chunk) differs by one byte
  for chunk in 0..<chunks:
    nowBytes[16] = byte(chunk)
    # Mix protocol not available in this libp2p version
    # res = if mountsMix:
    #   await gossipSub.publish(topic, nowBytes,
    #     publishParams = Opt.some(PublishParams(skipMCache: true, useCustomConn: true)),
    #   )
    # else:
    res = await gossipSub.publish(topic, nowBytes)
  info "publish result", 
    res = res,
    meshSize = gossipSub.mesh.getOrDefault(topic).len,
    gossipPeers = gossipSub.gossipsub.getOrDefault(topic).len,
    fanoutPeers = gossipSub.fanout.getOrDefault(topic).len,
    topicInTopics = (topic in gossipSub.topics),
    floodPublish = gossipSub.parameters.floodPublish
  if res <= 0:
    dst_testnode_publish_failures_total.inc(labelValues = [gMuxer, gPeerId])
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
            version = jsonBody["version"].getInt()

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

# Mix protocol not available in this libp2p version
# proc initializeGossipsub(switch: Switch, anonymize: bool, mixProto: Opt[MixProtocol] = Opt.none(MixProtocol)): GossipSub =
proc initializeGossipsub(switch: Switch, anonymize: bool): GossipSub =
  return GossipSub.init(
      switch = switch,
      triggerSelf = parseBool(getEnv("SELFTRIGGER", "true")),
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = anonymize,
      rng = libp2p.newRng(),
      # Mix callbacks disabled - mix protocol not available in this libp2p version
      # customConnCallbacks = if mountsMix and mixProto.isSome:
      #   Opt.some(CustomConnectionCallbacks(
      #     customConnCreationCB: makeMixConnCb(mixProto.get()),
      #     customPeerSelectionCB: makeMixPeerSelectCb()
      #   ))
      # else:
      #   Opt.none(CustomConnectionCallbacks)
    )

proc configureGossipsubParams(gossipSub: GossipSub) =
  let
    d = getEnvInt("GOSSIPSUB_D", 6)
    dLow = getEnvInt("GOSSIPSUB_D_LOW", 4)
    dHigh = getEnvInt("GOSSIPSUB_D_HIGH", 8)
    dScore = getEnvInt("GOSSIPSUB_D_SCORE", dLow)
    dOut = getEnvInt("GOSSIPSUB_D_OUT", d div 2)
    dLazy = getEnvInt("GOSSIPSUB_D_LAZY", d)

    heartbeatMs = getEnvInt("GOSSIPSUB_HEARTBEAT_MS", 1000)
    pruneBackoffSec = getEnvInt("GOSSIPSUB_PRUNE_BACKOFF_SEC", 60)

    maxHighPriorityQueueLen = getEnvInt("GOSSIPSUB_MAX_HIGH_PRIORITY_QUEUE_LEN", 256)
    maxMediumPriorityQueueLen = getEnvInt("GOSSIPSUB_MAX_MEDIUM_PRIORITY_QUEUE_LEN", 512)
    maxLowPriorityQueueLen = getEnvInt("GOSSIPSUB_MAX_LOW_PRIORITY_QUEUE_LEN", 1024)

    slowPeerPenaltyWeight = getEnvFloat("GOSSIPSUB_SLOW_PEER_PENALTY_WEIGHT", 0.0)
    slowPeerPenaltyThreshold = getEnvFloat("GOSSIPSUB_SLOW_PEER_PENALTY_THRESHOLD", 2.0)
    slowPeerPenaltyDecay = getEnvFloat("GOSSIPSUB_SLOW_PEER_PENALTY_DECAY", 0.2)

    decayIntervalMs = getEnvInt("GOSSIPSUB_DECAY_INTERVAL_MS", 1000)
    decayToZero = getEnvFloat("GOSSIPSUB_DECAY_TO_ZERO", 0.01)

    #gossipThreshold = getEnvFloat("GOSSIPSUB_GOSSIP_THRESHOLD", -100.0)
    #publishThreshold = getEnvFloat("GOSSIPSUB_PUBLISH_THRESHOLD", -1000.0)
    #graylistThreshold = getEnvFloat("GOSSIPSUB_GRAYLIST_THRESHOLD", -10000.0)
  
  gossipSub.parameters.floodPublish = getEnvBool("GOSSIPSUB_FLOOD_PUBLISH", true)
  gossipSub.parameters.opportunisticGraftThreshold = getEnvFloat("GOSSIPSUB_OPPORTUNISTIC_GRAFT_THRESHOLD", -10000)

  gossipSub.parameters.heartbeatInterval = heartbeatMs.milliseconds
  gossipSub.parameters.pruneBackoff = pruneBackoffSec.seconds
  gossipSub.parameters.gossipFactor = getEnvFloat("GOSSIPSUB_GOSSIP_FACTOR", 0.25)

  gossipSub.parameters.d = d
  gossipSub.parameters.dLow = dLow
  gossipSub.parameters.dHigh = dHigh
  gossipSub.parameters.dScore = dScore
  gossipSub.parameters.dOut = dOut
  gossipSub.parameters.dLazy = dLazy

  gossipSub.parameters.maxHighPriorityQueueLen = maxHighPriorityQueueLen
  gossipSub.parameters.maxMediumPriorityQueueLen = maxMediumPriorityQueueLen
  gossipSub.parameters.maxLowPriorityQueueLen = maxLowPriorityQueueLen

  gossipSub.parameters.slowPeerPenaltyWeight = slowPeerPenaltyWeight
  gossipSub.parameters.slowPeerPenaltyThreshold = slowPeerPenaltyThreshold
  gossipSub.parameters.slowPeerPenaltyDecay = slowPeerPenaltyDecay

  gossipSub.parameters.decayInterval = decayIntervalMs.milliseconds
  gossipSub.parameters.decayToZero = decayToZero

  #gossipSub.parameters.gossipThreshold = gossipThreshold
  #gossipSub.parameters.publishThreshold = publishThreshold
  #gossipSub.parameters.graylistThreshold = graylistThreshold

  info "Configured GossipSub mesh params",
    floodPublish = gossipSub.parameters.floodPublish,
    opportunisticGraftThreshold = gossipSub.parameters.opportunisticGraftThreshold,
    heartbeatMs = heartbeatMs,
    pruneBackoffSec = pruneBackoffSec,
    gossipFactor = gossipSub.parameters.gossipFactor,
    d = d,
    dLow = dLow,
    dHigh = dHigh,
    dScore = dScore,
    dOut = dOut,
    dLazy = dLazy

  info "Configured GossipSub queue and scoring params",
    maxHighPriorityQueueLen = maxHighPriorityQueueLen,
    maxMediumPriorityQueueLen = maxMediumPriorityQueueLen,
    maxLowPriorityQueueLen = maxLowPriorityQueueLen,
    slowPeerPenaltyWeight = slowPeerPenaltyWeight,
    slowPeerPenaltyThreshold = slowPeerPenaltyThreshold,
    slowPeerPenaltyDecay = slowPeerPenaltyDecay,
    decayIntervalMs = decayIntervalMs,
    decayToZero = decayToZero
    #gossipThreshold = gossipThreshold,
    #publishThreshold = publishThreshold,
    #graylistThreshold = graylistThreshold

proc subscribGossipsubTopic(gossipSub: GossipSub, topic: string) =
  gossipSub.topicParams[topic] = TopicParams(
    topicWeight: 1,
    firstMessageDeliveriesWeight: 1,
    firstMessageDeliveriesCap: 30,
    firstMessageDeliveriesDecay: 0.9
  )

  gossipSub.subscribe(topic, createMessageHandler())
  gossipSub.addValidator([topic], messageValidator)


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
      if inShadow:
        return err(exc.msg)
      #keep trying for service mode
      warn "Failed to resolve address", address = tAddress, error = exc.msg
      await sleepAsync(15.seconds)

proc connectGossipsubPeers(
  switch: Switch, muxer: string, networkSize: int, myId: int, connectTo: int
): Future[Result[int, string]] {.async.} =
  let rng = libp2p.newRng()
  var
    addrs: seq[MultiAddress] = @[]
    tAddresses: seq[string]
    connected = 0

  if inShadow:
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
    if connected >= connectTo: break
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
  randomize()
  let
    rng = libp2p.newRng()
    (myId, networkSize, connectTo, muxer, filePath, address) = getPeerDetails().valueOr:
      error "Error reading peer settings ",  err = error
      return
  
  # Set global metric labels
  gMuxer = muxer
  
  var
    gossipSub: GossipSub
    # Mix protocol not available in this libp2p version
    # mixPublicKey: SkPublicKey
    # mixPrivKey: SkPrivateKey
    builder = SwitchBuilder
      .new()
      .withNoise()
      .withAddress(MultiAddress.init(address).tryGet())
      .withMaxConnections(parseInt(getEnv("MAXCONNECTIONS", "250")))

  # Mix protocol not available in this libp2p version
  # if mountsMix or usesMix:
  #   let initResult = initializeMix(myId).valueOr:
  #     error "Failed to initialize mix", err = error
  #     return
  #   let multiAddr = initResult[0]
  #   mixPublicKey = initResult[1]
  #   mixPrivKey = initResult[2]
  #
  #   #mix protocol uses same address as yamux
  #   builder = builder.withRng(crypto.newRng())
  #             .withPrivateKey(PrivateKey(scheme: Secp256k1, skkey: mixPrivKey))
  # else:
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
  
  # Set peerId for metric labels
  gPeerId = $switch.peerInfo.peerId

  # Mix protocol not available in this libp2p version
  # if mountsMix or usesMix:
  #   writeMixInfoFiles(switch, myId, mixPublicKey, filePath)
  #   await sleepAsync(10.seconds)

  # if mountsMix:
  #   error "Mix not implemented"
  #   return
  # else:
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
  info "GossipSub codecs registered", codecs = gossipSub.codecs
  await sleepAsync(60.seconds)

  #connect with peers
  discard (await connectGossipsubPeers(switch, muxer, networkSize, myId, connectTo)).valueOr:
    error "Failed to establish any connections", error = error
    return

  await sleepAsync(15.seconds)  # Allow multiple heartbeats to build mesh
  let meshSize = gossipSub.mesh.getOrDefault("test").len
  let peersConnected = gossipSub.gossipsub.getOrDefault("test").len
  dst_testnode_mesh_size.set(meshSize.int64, labelValues = [gMuxer, gPeerId])
  dst_testnode_topic_peers.set(peersConnected.int64, labelValues = [gMuxer, gPeerId])

  info "Mesh details ",
    meshSize = meshSize,
    peersConnected = peersConnected
  info "Starting listening endpoint for publish controller"
  discard gossipSub.startHttpServer(myId)

  await sleepAsync(2.days)

waitFor(main())