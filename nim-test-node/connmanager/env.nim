import strutils, os
import chronos, chronicles
import stew/byteutils
import libp2p, libp2p/[multiaddress, crypto/secp]
from nativesockets import getHostname

type
  NodeRole* = enum
    RoleHub, RolePeer

  ReconnectMode* = enum
    ReconnectNone, ReconnectAggressive, ReconnectBeforeGrace

  HubConfig* = object
    lowWater*: int
    highWater*: int
    gracePeriodS*: int
    silencePeriodS*: int
    maxConnections*: int       # 0 = no hard cap (Runs A/B/C), >0 adds semaphore (Run D)
    protectedPeers*: seq[PeerId]
    outboundPeers*: seq[string]  # addresses hub dials proactively (Group A in Run A)
    numHubs*: int              # total hub replicas; >1 triggers hub-to-hub dialing
    hubNamespace*: string      # k8s namespace used to build peer-hub DNS addresses

  PeerConfig* = object
    hubAddrs*: seq[string]     # one or more hub addresses to connect to (multi-hub support)
    dialOut*: bool             # true = peer dials hub; false = peer listens, hub dials it
    reconnect*: ReconnectMode
    reconnectIntervalS*: int   # for ReconnectBeforeGrace: cycle connection every N seconds
    privateKey*: Opt[PrivateKey]

let
  prometheusPort* = Port(8008)
  myPort* = Port(parseInt(getEnv("PORT", "5000")))

proc getRole*(): NodeRole =
  parseEnum[NodeRole](getEnv("NODE_ROLE", "RoleHub"))

proc parseHubConfig*(): HubConfig =
  result.lowWater = parseInt(getEnv("WATERMARK_LOW", "10"))
  result.highWater = parseInt(getEnv("WATERMARK_HIGH", "20"))
  result.gracePeriodS = parseInt(getEnv("WATERMARK_GRACE_PERIOD_S", "0"))
  result.silencePeriodS = parseInt(getEnv("WATERMARK_SILENCE_PERIOD_S", "2"))
  result.maxConnections = parseInt(getEnv("MAX_CONNECTIONS", "0"))

  let protectedStr = getEnv("PROTECTED_PEERS", "")
  for entry in protectedStr.split(','):
    let s = entry.strip()
    if s.len == 0: continue
    let peerId = PeerId.init(s).valueOr:
      warn "Skipping invalid peer ID in PROTECTED_PEERS", raw = s
      continue
    result.protectedPeers.add(peerId)

  let outboundStr = getEnv("OUTBOUND_PEERS", "")
  for entry in outboundStr.split(','):
    let s = entry.strip()
    if s.len > 0:
      result.outboundPeers.add(s)

  result.numHubs = parseInt(getEnv("NUM_HUBS", "1"))
  result.hubNamespace = getEnv("HUB_NAMESPACE", "nimlibp2p")

proc parsePeerConfig*(): PeerConfig =
  # HUB_ADDRS: comma-separated list of hub addresses (multi-hub).
  # Falls back to HUB_ADDR (single address) for backwards compatibility.
  let hubAddrsStr = getEnv("HUB_ADDRS", "")
  if hubAddrsStr.len > 0:
    for entry in hubAddrsStr.split(','):
      let s = entry.strip()
      if s.len > 0:
        result.hubAddrs.add(s)
  else:
    result.hubAddrs = @[getEnv("HUB_ADDR", "hub:5000")]

  result.dialOut = getEnv("DIAL_OUT", "true").toLowerAscii() == "true"

  result.reconnect =
    case getEnv("RECONNECT", "none").toLowerAscii()
    of "aggressive": ReconnectAggressive
    of "before_grace": ReconnectBeforeGrace
    else: ReconnectNone

  result.reconnectIntervalS = parseInt(getEnv("RECONNECT_INTERVAL_S", "55"))

  # PRIVATE_KEYS: comma-separated list; pod picks its key by ordinal extracted
  # from the StatefulSet hostname (e.g. "protected-2" → index 2).
  # Falls back to PRIVATE_KEY (single key) if PRIVATE_KEYS is not set.
  let privKeysStr = getEnv("PRIVATE_KEYS", "")
  let privKeyHex =
    if privKeysStr.len > 0:
      let keys = privKeysStr.split(',')
      let hostname = getHostname()
      let parts = hostname.split('-')
      let idx = try: parseInt(parts[^1]) except CatchableError: 0
      if idx < keys.len: keys[idx].strip() else: ""
    else:
      getEnv("PRIVATE_KEY", "")

  if privKeyHex.len > 0:
    try:
      let keyBytes = hexToSeqByte(privKeyHex)
      result.privateKey = Opt.some(PrivateKey.init(keyBytes).tryGet())
    except CatchableError as exc:
      warn "Invalid PRIVATE_KEY, using random key", error = exc.msg
