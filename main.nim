import stew/endians2, stew/byteutils, tables, strutils, os, osproc, chronos
#import libp2p, libp2p/protocols/pubsub/rpc/messages
#import libp2p/muxers/mplex/lpchannel, libp2p/protocols/ping
import "../../nim-libp2p/libp2p", "../../nim-libp2p/libp2p/protocols/pubsub/rpc/messages"
import "../../nim-libp2p/libp2p/muxers/mplex/lpchannel", "../../nim-libp2p/libp2p/protocols/ping"
import sequtils, hashes, math, metrics, metrics/chronos_httpserver, httpclient
from times import getTime, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname

let
  inShadow = existsEnv("SHADOWENV")
  prometheusPort = Port(8008)
  myPort = 5000 + parseInt(getEnv("PEERNUMBER", "0"))
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

proc main {.async.} =
  let
    hostname = getHostname()
    myId = if inShadow: 
      parseInt(hostname[4..^1])
    else:
      parseInt(hostname.split('.')[0].split('-')[1])
    #myId = parseInt(getEnv("PEERNUMBER", "0"))               #Alternatively, we can use ENV
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

  echo "Hostname: ", hostname, "myId", myId
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
  echo "Starting metrics HTTP server"
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

  echo "Listening on ", switch.peerInfo.addrs
  echo myId, ", ", isPublisher, ", ", switch.peerInfo.peerId
  echo "Waiting 60 seconds for node building..."
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
      echo "Failed to ping"

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

    echo "Trying to resolve ", tAddress
    
    try:
      let addrs = resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())
      echo tAddress, " resolved: ", addrs, " - dialing!"
      let peerId = await switch.connect(addrs[0], allowUnknownPeerId=true).wait(5.seconds)
      #asyncSpawn pinger(peerId)
      connected.inc()
      echo "Connected to ", tAddress, " (", connected, "/", connectTo, ")"
    except CatchableError as exc:
      echo "Failed to dial ", tAddress, ": ", exc.msg
      echo "Waiting 15 seconds..."
      await sleepAsync(15.seconds)
  echo "Mesh size: ", gossipSub.mesh.getOrDefault("test").len

  let offset = if inShadow: 1 else: 0
  var senderId = publisherId
  for msgNumber in 0 ..< messageCount:
    await sleepAsync(msgRate.milliseconds)
    if myId == senderId:
      let
        now = getTime()
        nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))

      echo "Publishing turn is: ", myId, "sending at ", now
      var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](msgSize div chunks)
      for chunk in 0..<chunks:
        nowBytes[10] = byte(chunk)
        doAssert((await gossipSub.publish("test", nowBytes)) > 0)
    
    if senderRotation:
      senderId = (senderId + 1) mod (networkSize + offset)
      if inShadow and senderId == 0:
        senderId = 1

  await sleepAsync(15.seconds)
  if metricsServer.isOk() and inShadow:
    echo "Fetching metrics"
    await sleepAsync((myId*60).milliseconds)
    let cmd = "curl -s --connect-timeout 5 --max-time 5 -o metrics_peer" & 
            $myId & ".txt http://localhost:" & $prometheusPort & "/metrics"
    
    let exitCode = execCmd(cmd)
    if exitCode == 0:
      echo "Metrics saved for peer ", myId
    else:
      echo "Failed to fetch metrics for peer ", myId, ": curl exit code ", exitCode
    await sleepAsync(6.seconds)
    
  quit(0)

waitFor(main())