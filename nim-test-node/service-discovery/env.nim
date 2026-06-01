import os, strutils, sequtils
import chronos, chronicles, results
import stew/byteutils
from nativesockets import getHostname

type
  NodeRole* = enum
    RoleBootstrap, RoleAdvertiser, RoleDiscoverer, RoleHybrid

  NodeConfig* = object
    nodeIndex*: int
    muxer*: string
    listenPort*: Port
    listenAddress*: string
    role*: NodeRole
    bootstrapService*: string
    advertiseServices*: seq[string]
    discoverServices*: seq[string]
    serviceData*: seq[byte]
    lookupInterval*: Duration
    startupJitterMs*: int
    healthPort*: Port
    safetyParam*: float64
    ipSimCoefficient*: float64
    advertExpiry*: Duration
    xprPublishing*: bool

proc parseIntEnv(name: string, defaultValue: string): Result[int, string] =
  let raw = getEnv(name, defaultValue)
  try:
    ok(parseInt(raw))
  except ValueError:
    err("Invalid integer for " & name & ": " & raw)

proc parseFloatEnv(name: string, defaultValue: string): Result[float64, string] =
  let raw = getEnv(name, defaultValue)
  try:
    ok(parseFloat(raw))
  except ValueError:
    err("Invalid float for " & name & ": " & raw)

proc parseBoolEnv(name: string, defaultValue: string): Result[bool, string] =
  let raw = getEnv(name, defaultValue).toLowerAscii()
  case raw
  of "1", "true", "yes", "y", "on":
    ok(true)
  of "0", "false", "no", "n", "off":
    ok(false)
  else:
    err("Invalid boolean for " & name & ": " & raw)

proc parseServiceList(raw: string): seq[string] =
  raw.split(",").mapIt(it.strip()).filterIt(it.len > 0)

proc getNodeConfig*(): Result[NodeConfig, string] =
  let hostname = getHostname()

  let nodeIndex =
    try:
      parseInt(hostname.split('-')[^1])
    except ValueError:
      0

  let muxer = getEnv("MUXER", "yamux").toLowerAscii()
  if muxer notin ["quic", "yamux", "mplex"]:
    return err("Unknown muxer type: " & muxer)

  let listenPort = parseIntEnv("PORT", "5000").valueOr:
    return err(error)
  if listenPort <= 0 or listenPort > 65535:
    return err("PORT out of range: " & $listenPort)

  let role = try:
    parseEnum[NodeRole](getEnv("NODE_ROLE", "RoleBootstrap"))
  except ValueError:
    return err(
      "Unknown NODE_ROLE. Expected one of: RoleBootstrap, RoleAdvertiser, RoleDiscoverer, RoleHybrid"
    )

  let healthPort = parseIntEnv("HEALTH_PORT", "8645").valueOr:
    return err(error)
  if healthPort <= 0 or healthPort > 65535:
    return err("HEALTH_PORT out of range: " & $healthPort)

  let startupJitterMs =
    if existsEnv("STARTUP_JITTER_MS"):
      parseIntEnv("STARTUP_JITTER_MS", "0").valueOr:
        return err(error)
    else:
      let step = parseIntEnv("STARTUP_JITTER_STEP_MS", "200").valueOr:
        return err(error)
      nodeIndex * step

  if startupJitterMs < 0:
    return err("STARTUP_JITTER_MS must be >= 0")

  let lookupIntervalSeconds = parseIntEnv("LOOKUP_INTERVAL_SECONDS", "15").valueOr:
    return err(error)
  if lookupIntervalSeconds <= 0:
    return err("LOOKUP_INTERVAL_SECONDS must be > 0")

  let safetyParam = parseFloatEnv("SD_SAFETY_PARAM", "0.0").valueOr:
    return err(error)
  if safetyParam < 0.0:
    return err("SD_SAFETY_PARAM must be >= 0")

  let ipSimCoefficient = parseFloatEnv("SD_IP_SIM_COEFF", "0.0").valueOr:
    return err(error)
  if ipSimCoefficient < 0.0:
    return err("SD_IP_SIM_COEFF must be >= 0")

  let advertExpirySeconds = parseIntEnv("SD_ADVERT_EXPIRY_SECONDS", "900").valueOr:
    return err(error)
  if advertExpirySeconds <= 0:
    return err("SD_ADVERT_EXPIRY_SECONDS must be > 0")

  let xprPublishing = parseBoolEnv("SD_XPR_PUBLISHING", "true").valueOr:
    return err(error)

  let advertiseServices = parseServiceList(getEnv("ADVERTISE_SERVICES", ""))
  let discoverServices = parseServiceList(getEnv("DISCOVER_SERVICES", ""))

  if role in [RoleAdvertiser, RoleHybrid] and advertiseServices.len == 0:
    return err("ADVERTISE_SERVICES is required for " & $role)

  if role in [RoleDiscoverer, RoleHybrid] and discoverServices.len == 0:
    return err("DISCOVER_SERVICES is required for " & $role)

  let listenAddress =
    if muxer == "quic":
      "/ip4/0.0.0.0/udp/" & $listenPort & "/quic-v1"
    else:
      "/ip4/0.0.0.0/tcp/" & $listenPort

  let cfg = NodeConfig(
    nodeIndex: nodeIndex,
    muxer: muxer,
    listenPort: Port(listenPort),
    listenAddress: listenAddress,
    role: role,
    bootstrapService: getEnv("SERVICE", "service-discovery:5000"),
    advertiseServices: advertiseServices,
    discoverServices: discoverServices,
    serviceData: getEnv("SERVICE_DATA", "").toBytes(),
    lookupInterval: lookupIntervalSeconds.seconds,
    startupJitterMs: startupJitterMs,
    healthPort: Port(healthPort),
    safetyParam: safetyParam,
    ipSimCoefficient: ipSimCoefficient,
    advertExpiry: advertExpirySeconds.seconds,
    xprPublishing: xprPublishing,
  )

  info "Node config loaded",
    role = cfg.role,
    nodeIndex = cfg.nodeIndex,
    muxer = cfg.muxer,
    listenAddress = cfg.listenAddress,
    advertiseServices = cfg.advertiseServices,
    discoverServices = cfg.discoverServices,
    bootstrapService = cfg.bootstrapService

  ok(cfg)
