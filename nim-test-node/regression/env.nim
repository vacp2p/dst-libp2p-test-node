import strutils, os, osproc
import chronos, metrics/chronos_httpserver, chronicles
from nativesockets import getHostname, getHostByName

type
  NodeType* = enum
    RoleBootstrap, RoleNormal

proc shadowSelfIp(hostname: string): string =
  ## Shadow doesn't expand a 0.0.0.0 listen into a routable address, so
  ## switch.peerInfo.addrs ends up empty and kad-dht can't advertise a dialable
  ## address for us. Resolve our own hostname to the Shadow-assigned IP and listen
  ## on that instead (host names resolve fine inside Shadow).
  try:
    for ip in getHostByName(hostname).addrList:
      if not ip.startsWith("127.") and ip != "0.0.0.0":
        return ip
  except CatchableError as e:
    warn "Could not resolve self IP; falling back to 0.0.0.0",
      hostname = hostname, error = e.msg
  return "0.0.0.0"

let
  inShadow* = getEnv("SHADOWENV").cmpIgnoreCase("true") == 0    #If Running for shadow simulator 
  httpPublishPort* = Port(8645)
  prometheusPort* = Port(8008)
  myPort* = Port(5000)
  chunks* = parseInt(getEnv("FRAGMENTS", "1"))                  #No. of fragments for each message
  start_sleep* = parseInt(getEnv("STARTSLEEP", "180"))          # Give time to deploy all nodes before starting connections
  metricsIntervalS* = parseInt(getEnv("METRICS_INTERVAL_S", "300"))  #storeMetrics scrape interval (s); short for shadow


proc getPeerDetails*(): Result[(int, int, int, string, string, string, NodeType, string), string] =
  let
    hostname = getHostname()
    myId = parseInt(hostname.split('-')[^1])
    networkSize = parseInt(getEnv("PEERS", "100"))
    connectTo = parseInt(getEnv("CONNECTTO", "10"))
    muxer = getEnv("MUXER", "yamux")
    filePath = if inShadow: "../" else: getEnv("FILEPATH", "./")
    # k8s expands 0.0.0.0 to the pod IP; Shadow can't, so resolve our own IP there.
    listenIp = if inShadow: shadowSelfIp(hostname) else: "0.0.0.0"
    address = if muxer.toLowerAscii() == "quic":
      "/ip4/" & listenIp & "/udp/" & $myPort & "/quic-v1"
    else:
      "/ip4/" & listenIp & "/tcp/" & $myPort
    # RoleNormal + static discovery keep the legacy behaviour when the env is unset.
    nodeRole = parseEnum[NodeType](getEnv("NODE_ROLE", "RoleNormal"))
    discovery = getEnv("DISCOVERY", "static")

  if muxer.toLowerAscii() notin ["quic", "yamux", "mplex"]:
    return err("Unknown muxer type : " & muxer)

  # connectTo only constrains the static mesh; kad-dht discovers peers dynamically.
  if discovery != "kad-dht" and connectTo >= networkSize:
    return err("Not enough peers to make target connections. Network size : " & $networkSize)

  info "Host info ", hostname = hostname, peer = myId, muxer = muxer, inShadow = inShadow, address = address, start_sleep = start_sleep, role = nodeRole, discovery = discovery

  return ok((myId, networkSize, connectTo, muxer, filePath, address, nodeRole, discovery))

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