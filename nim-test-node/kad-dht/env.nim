import strutils, os, sequtils
import chronos, metrics/chronos_httpserver, chronicles
import std/[random]
import libp2p, libp2p/[multiaddress, crypto/secp]
from nativesockets import getHostname

# --- Configuration & Types ---
type
  NodeType* = enum
    RoleBootstrap, RoleNormal, RoleProbe

let
  httpPublishPort* = Port(8645)
  prometheusPort* = Port(8008)
  myPort* = Port(parseInt(getEnv("PORT", "5000")))

proc getPeerDetails*(): Result[(int, string, string, NodeType, string), string] =
  let 
    hostname = getHostname()
    #myId = parseInt(hostname.split('-')[^1])
    myId = 0
    muxer = getEnv("MUXER", "yamux")
    address = if muxer.toLowerAscii() == "quic":
      "/ip4/0.0.0.0/udp/" & $myPort & "/quic-v1"
    else:
      "/ip4/0.0.0.0/tcp/" & $myPort
    nodeRole = parseEnum[NodeType](getEnv("NODE_ROLE", "RoleNormal"))
    discovery = getEnv("DISCOVERY", "kad-dht")

  if muxer.toLowerAscii() notin ["quic", "yamux", "mplex"]:
    return err("Unknown muxer type : " & muxer)
  
  info "Host info ", hostname = hostname, peer = myId, muxer = muxer, address = address

  return ok((myId, muxer, address, nodeRole, discovery))

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

proc resolveAddress*(muxer: string, tAddress: string): Future[Result[seq[MultiAddress], string]] {.async.} =
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
      warn "Failed to resolve address", address = tAddress, error = exc.msg
      await sleepAsync(15.seconds)

proc resolveService*(muxer: string, service: string): Future[Result[seq[MultiAddress], string]] {.async.} =
  # If the service doesn't contain a port, append the default one
  let tAddress = if ":" in service: service else: service & ":" & $myPort

  # Call the existing resolveAddress helper
  let resolvedAddrs = (await resolveAddress(muxer, tAddress)).valueOr:
    return err("Failed to resolve address " & tAddress & ": " & error)

  var addrs = resolvedAddrs
  if addrs.len > 0:
    let rng = newRng()
    rng.shuffle(addrs)

  return ok(addrs)
