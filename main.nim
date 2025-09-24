import stew/endians2, stew/byteutils, tables, strutils, os, osproc, json
import chronos, chronos/apps/http/[httpserver, httptable]
import libp2p, libp2p/protocols/pubsub/rpc/messages
import libp2p/muxers/mplex/lpchannel, libp2p/protocols/ping
import sequtils, hashes, math, metrics, metrics/chronos_httpserver
from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname

let
  inShadow = existsEnv("SHADOWENV")
  detatchedController = existsEnv("CONTROLLER")
  httpPublishPort = Port(8645)
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
  info "Fetching metrics"
  await sleepAsync((myId*60).milliseconds)
  let cmd = "curl -s --connect-timeout 5 --max-time 5 -o metrics_peer" & 
          $myId & ".txt http://localhost:" & $prometheusPort & "/metrics"
  
  let exitCode = execCmd(cmd)
  if exitCode == 0:
    info "Metrics saved for peer ", peer = myId
  else:
    info "Failed to fetch metrics for peer ", peer = myId, curlExitCode = $exitCode
  await sleepAsync(6.seconds)

proc publishNewMessage(gossipSub: GossipSub, myId: int, msgSize: int): Future[(Time, int)] {.async.} =
  let
    now = getTime()
    nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
  var 
    res = 0
    nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](msgSize div chunks)

  for chunk in 0..<chunks:
    nowBytes[10] = byte(chunk)
    res = await gossipSub.publish("test", nowBytes)
  
  return (now, res)

#http endpoint for detatched controller
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
          let (publishTime, publishResult) = await gossipSub.publishNewMessage(myId, msgSize)
          
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

proc main {.async.} =
  let
    hostname = getHostname()
    myId = if inShadow:
      parseInt(hostname[4..^1])
    else:
      parseInt(hostname.split('-')[^1])
    networkSize = parseInt(getEnv("PEERS", "1000"))
    msgRate = parseInt(getEnv("MSGRATE", "1000"))
    msgSize = parseInt(getEnv("MSGSIZE", "1000"))
    messageCount = parseInt(getEnv("PUBLISHERS", "10"))
    publisherId = parseInt(getEnv("PUBLISHERID", "1"))
    connectTo = parseInt(getEnv("CONNECTTO", "10"))
    senderRotation = getEnv("ROTATEPUBLISHER", "0") != "0"

    isPublisher = if senderRotation: 
      myId in publisherId..(publisherId + messageCount)
    else:
      myId == publisherId
    #isAttacker = (not isPublisher) and myId - publisherCount <= client.param(int, "attacker_count")
    isAttacker = false
    rng = libp2p.newRng()

  info "Host info ", host = hostname, peer = myId
  let
    myaddress = "0.0.0.0" & ":" & $myPort
    address = initTAddress(myaddress)
    switch =
      SwitchBuilder
        .new()
        .withAddress(MultiAddress.init(address).tryGet())
        .withRng(rng)
        .withYamux()
        #.withQUIC()
        .withMaxConnections(250)
        .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
        #.withPlainText()
        .withNoise()
        .build()
    gossipSub = GossipSub.init(
      switch = switch,
#      triggerSelf = true,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
      )
    pingProtocol = Ping.new(rng=rng)
  # Metrics
  info "Starting metrics server"
  let metricsServer = startMetricsServer(parseIpAddress("0.0.0.0"), prometheusPort)

  gossipSub.parameters.floodPublish = true
  #gossipSub.parameters.lazyPushThreshold = 1_000_000_000
  #gossipSub.parameters.lazyPushThreshold = 0
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
  switch.mount(pingProtocol)
  await switch.start()
  #defer: await switch.stop()

  info "Listening on ", address = switch.peerInfo.addrs
  info "Peer details ", peer = myId, peerId = switch.peerInfo.peerId
  #Wait for node building
  await sleepAsync(60.seconds)

  proc pinger(peerId: PeerId) {.async.} =
    try:
      await sleepAsync(20.seconds)
      while true:
        let stream = await switch.dial(peerId, PingCodec)
        let delay = await pingProtocol.ping(stream)
        await stream.close()
        #echo delay
        await sleepAsync(delay)
    except:
      info "Failed to ping"

  var 
    connected = 0
    peersInfo = toSeq(1..networkSize).filterIt(it != myId)
  rng.shuffle(peersInfo)

  for peerInfo in peersInfo:
    if connected > connectTo: break
    
    let tAddress = if inShadow:
        "peer" & $peerInfo & ":" & $myPort                            # Shadow format
    else:
        "pod-" & $(peerInfo-1) & ".nimp2p-service:" & $myPort         # k8s format

    info "Trying to resolve ", theirAddress = tAddress
    
    try:
      let addrs = resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())
      info "Address resolved ", theirAddress = tAddress, resolved = addrs
      let peerId = await switch.connect(addrs[0], allowUnknownPeerId=true).wait(5.seconds)
      #asyncSpawn pinger(peerId)
      connected.inc()
      info "Connected!: current connections ", connected = $connected, desired = connectTo
    except CatchableError as exc:
      info "Failed to dial ", theirAddress = tAddress, message = exc.msg
      await sleepAsync(15.seconds)
  info "Mesh size ", mesh = gossipSub.mesh.getOrDefault("test").len
  
  if detatchedController:
    info "Starting listening endpoint for publish controller"
    discard gossipSub.startHttpServer(myId)
    while true:
      await sleepAsync(1.hours)
  else:
    let offset = if inShadow: 1 else: 0
    var senderId = publisherId
    for msgNumber in 0 ..< messageCount:
      await sleepAsync(msgRate.milliseconds)
      if myId == senderId:
        let (publishTime, publishResult) = await gossipSub.publishNewMessage(myId, msgSize)
        info "published message : ", time = $publishTime, peer = myId, status = publishResult
      if senderRotation:
        senderId = (senderId + 1) mod (networkSize + offset)
        if inShadow and senderId == 0:
          senderId = 1
    await sleepAsync(25.seconds)

  if metricsServer.isOk() and inShadow:
    await storeMetrics(myId)

  quit(0)

waitFor(main())