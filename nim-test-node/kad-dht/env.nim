import strutils, os, osproc
import chronos, metrics/chronos_httpserver, chronicles
from nativesockets import getHostname

let
  httpPublishPort* = Port(8645)
  prometheusPort* = Port(8008)
  myPort* = Port(5001)

proc getPeerDetails*(): Result[(int, string, string), string] =
  let 
    # hostname = getHostname()
    # myId = parseInt(hostname.split('-')[^1])
    hostname = "test"
    myId = 0
    muxer = getEnv("MUXER", "yamux")
    address = if muxer.toLowerAscii() == "quic":
      "/ip4/0.0.0.0/udp/" & $myPort & "/quic-v1"
    else:
      "/ip4/0.0.0.0/tcp/" & $myPort
  
  if muxer.toLowerAscii() notin ["quic", "yamux", "mplex"]:
    return err("Unknown muxer type : " & muxer)
  
  info "Host info ", hostname = hostname, peer = myId, muxer = muxer, address = address

  return ok((myId, muxer, address))

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
