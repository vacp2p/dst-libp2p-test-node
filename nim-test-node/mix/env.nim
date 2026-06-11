import strutils, os, osproc
import chronos, metrics/chronos_httpserver, chronicles
import libp2p_mix/sphinx     # PathLength
from nativesockets import getHostname

const GossipSubMeshDegree* = 6   # GossipSub mesh degree; mix peer-selection fan-out must match

type GossipSubMode* = enum
  Regular    # GossipSub direct publishes
  Anonymous  # GossipSub publishes routed through mix
  Off        # GossipSub not mounted

proc parseGossipSubMode(s: string): Result[GossipSubMode, string] =
  case s.strip.toLowerAscii:
  of "regular": ok(Regular)
  of "anonymous": ok(Anonymous)
  of "off": ok(Off)
  else: err("Unknown GOSSIPSUBMODE: '" & s & "'. Must be regular, anonymous, or off.")

let
  inShadow* = getEnv("SHADOWENV").cmpIgnoreCase("true") == 0    #If Running for shadow simulator
  httpPublishPort* = Port(8645)
  prometheusPort* = Port(8008)
  myPort* = Port(5000)
  chunks* = parseInt(getEnv("FRAGMENTS", "1"))                  #No. of fragments for each message
  start_sleep* = parseInt(getEnv("STARTSLEEP", "180"))          # Give time to deploy all nodes before starting connections
  metricsIntervalS* = parseInt(getEnv("METRICS_INTERVAL_S", "300"))  #storeMetrics scrape interval (s); short for shadow

  # Mix protocol flags.
  mixEnabled* = parseBool(getEnv("MIXENABLED", "false"))
  gossipSubMode* = parseGossipSubMode(getEnv("GOSSIPSUBMODE", "regular")).valueOr:
    raise newException(ValueError, error)
  numMix* = parseInt(getEnv("NUMMIX", getEnv("PEERS", "100")))   # Number of mix-capable peers; defaults to PEERS.


proc getPeerDetails*(): Result[(int, int, int, string, string, string), string] =
  let 
    hostname = getHostname()
    myId = parseInt(hostname.split('-')[^1])
    networkSize = parseInt(getEnv("PEERS", "100"))
    connectTo = parseInt(getEnv("CONNECTTO", "10"))
    muxer = getEnv("MUXER", "yamux")
    filePath = getEnv("FILEPATH", "./")
    address = if muxer.toLowerAscii() == "quic":
      "/ip4/0.0.0.0/udp/" & $myPort & "/quic-v1"
    else:
      "/ip4/0.0.0.0/tcp/" & $myPort
  
  if muxer.toLowerAscii() notin ["quic", "yamux", "mplex"]:
    return err("Unknown muxer type : " & muxer)

  if connectTo >= networkSize:
    return err("Not enough peers to make target connections. Network size : " & $networkSize)
  
  info "Host info ", hostname = hostname, peer = myId, muxer = muxer, inShadow = inShadow, address = address, start_sleep = start_sleep

  return ok((myId, networkSize, connectTo, muxer, filePath, address))

proc validateMixConfig*(): Result[void, string] =
  if gossipSubMode == Anonymous and not mixEnabled:
    return err("GOSSIPSUBMODE=anonymous requires MIXENABLED=true")
  # Mix library excludes both self and destination from the path-selection
  # pool when destination is also a mix node.
  if mixEnabled and numMix < PathLength + 2:
    return err("NUMMIX (" & $numMix & ") must be >= " & $(PathLength + 2) &
      " (sphinx path " & $PathLength & " + self + destination)")
  ok()

#Prometheus metrics
proc startMetricsServer*(
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

#log metrics if needed (useful for shadow simulations)
proc storeMetrics*(myId: int) {.async.} =
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
      return
    await sleepAsync(metricsIntervalS.seconds)