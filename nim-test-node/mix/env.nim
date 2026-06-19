import strutils, os
import chronos, metrics/chronos_httpserver, chronicles
import libp2p_mix/sphinx     # PathLength
from nativesockets import getHostname

let
  localSmoke* = getEnv("LOCALSMOKE").cmpIgnoreCase("true") == 0    # Local smoke-test mode: discover peers by pod-N hostname instead of SERVICE DNS
  prometheusPort* = Port(8008)
  myPort* = Port(5000)
  start_sleep* = parseInt(getEnv("STARTSLEEP", "180"))          # Give time to deploy all nodes before starting connections
  numMix* = parseInt(getEnv("NUMMIX", getEnv("PEERS", "100")))   # Number of Mix nodes; defaults to PEERS.


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

  info "Host info ", hostname = hostname, peer = myId, muxer = muxer, localSmoke = localSmoke, address = address, start_sleep = start_sleep

  return ok((myId, networkSize, connectTo, muxer, filePath, address))

proc validateMixConfig*(): Result[void, string] =
  # Mix library excludes both self and destination from the path-selection
  # pool when destination is also a Mix node.
  if numMix < PathLength + 2:
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
