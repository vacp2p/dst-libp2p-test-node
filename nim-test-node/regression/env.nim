import strutils, os, osproc
from std/net import getPrimaryIPAddr, IpAddress, `$`
import chronos, metrics/chronos_httpserver, chronicles
from nativesockets import getHostname

type
  NodeType* = enum
    RoleBootstrap, RoleNormal

let
  inShadow* = getEnv("SHADOWENV").cmpIgnoreCase("true") == 0    #If Running for shadow simulator 
  httpPublishPort* = Port(8645)
  prometheusPort* = Port(8008)
  myPort* = Port(5000)
  chunks* = parseInt(getEnv("FRAGMENTS", "1"))                  #No. of fragments for each message
  # Per-pod startup jitter (pod index * this ms) to spread bootstrap dials and avoid
  # simultaneous-dial collisions. Mainly for Shadow, which starts all hosts at the same
  # simulated instant; real deployments get this spread naturally. Node availability
  # before connect is handled by the readiness probe + publish_not_ready_addresses
  # (10ksim#315), so no flat sync delay is needed here. The flat delay also guarded against
  # static-mode connection hoarding (early nodes filling their slots before latecomers dial);
  # that stays fine at 1000 nodes here, since each dials a sparse fixed set so inbound sits at
  # ~CONNECTTO on average, well under the connection cap.
  startupJitterStepMs* = parseInt(getEnv("STARTUP_JITTER_STEP_MS", "50"))
  metricsIntervalS* = parseInt(getEnv("METRICS_INTERVAL_S", "300"))  #storeMetrics scrape interval (s); short for shadow


proc listenHost*(): string =
  ## The interface the pod routes out of; 0.0.0.0 would announce loopback too.
  try:
    $getPrimaryIPAddr()
  except CatchableError:
    warn "Could not determine the primary interface, falling back to 0.0.0.0"
    "0.0.0.0"

proc getPeerDetails*(): Result[(int, string, string, string, NodeType), string] =
  let
    hostname = getHostname()
    listenIp = listenHost()
    myId = try: parseInt(hostname.split('-')[^1])
           except ValueError: 0
    muxer = getEnv("MUXER", "yamux")
    filePath = if inShadow: "../" else: getEnv("FILEPATH", "./")
    address = if muxer.toLowerAscii() == "quic":
      "/ip4/" & listenIp & "/udp/" & $myPort & "/quic-v1"
    else:
      "/ip4/" & listenIp & "/tcp/" & $myPort
    nodeRole = parseEnum[NodeType](getEnv("NODE_ROLE", "RoleNormal"))

  if muxer.toLowerAscii() notin ["quic", "yamux", "mplex"]:
    return err("Unknown muxer type : " & muxer)

  info "Host info ", hostname = hostname, peer = myId, muxer = muxer, inShadow = inShadow, address = address, jitterStepMs = startupJitterStepMs, role = nodeRole

  return ok((myId, muxer, filePath, address, nodeRole))

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