import strutils, os
import chronos, metrics/chronos_httpserver, chronicles
import libp2p_mix/sphinx     # PathLength
from nativesockets import getHostname

proc publishedHostname*(): string =
  getEnv("PUBLISHED_HOSTNAME", getHostname())

proc hostnameMultiaddrProtocol(hostname: string): string =
  if hostname.contains(":"):
    "ip6"
  else:
    let parts = hostname.split(".")
    var isIp4 = parts.len == 4
    for part in parts:
      if part.len == 0:
        isIp4 = false
        break
      for c in part:
        if c notin {'0'..'9'}:
          isIp4 = false
          break
    if isIp4:
      "ip4"
    else:
      "dns4"

let
  localSmoke* = getEnv("LOCALSMOKE").cmpIgnoreCase("true") == 0    # Local smoke-test mode: discover peers by pod-N hostname instead of SERVICE DNS
  mixPingEnabled* = getEnv("MIXPING", "true").cmpIgnoreCase("true") == 0
  prometheusPort* = Port(8008)
  myPort* = Port(5000)
  start_sleep* = parseInt(getEnv("STARTSLEEP", "180"))          # Give time to deploy all nodes before starting connections
  numMix* = parseInt(getEnv("NUMMIX", getEnv("PEERS", "100")))   # Number of Mix nodes; defaults to PEERS.

proc publishedPort*(myId: int): Port =
  let port = getEnv("PUBLISHED_PORT")
  if port.len > 0:
    return Port(parseInt(port))

  let portBase = getEnv("PUBLISHED_PORT_BASE")
  if portBase.len > 0:
    return Port(parseInt(portBase) + myId)

  myPort

proc publishedAddress*(myId: int, muxer: string): string =
  let
    hostname = publishedHostname()
    proto = hostnameMultiaddrProtocol(hostname)
    transport = if muxer.toLowerAscii() == "quic":
      "/udp/" & $publishedPort(myId) & "/quic-v1"
    else:
      "/tcp/" & $publishedPort(myId)

  "/" & proto & "/" & hostname & transport


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

  info "Host info ", hostname = hostname, publishedHostname = publishedHostname(), publishedPort = publishedPort(myId), publishedAddress = publishedAddress(myId, muxer), peer = myId, muxer = muxer, localSmoke = localSmoke, mixPingEnabled = mixPingEnabled, address = address, start_sleep = start_sleep

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
