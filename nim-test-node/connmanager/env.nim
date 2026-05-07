import strutils, os
import chronos, chronicles
import stew/byteutils
import libp2p, libp2p/[multiaddress, crypto/secp]
from nativesockets import getHostname

type
  NodeRole* = enum
    RoleHub, RolePeer

  ReconnectMode* = enum
    ReconnectNone, ReconnectAggressive

  HubConfig* = object
    lowWater*: int
    highWater*: int
    gracePeriodS*: int
    silencePeriodS*: int
    maxConnections*: int       # 0 = no hard cap (Runs A/B/C), >0 adds semaphore (Run D)
    protectedPeers*: seq[PeerId]
    outboundPeers*: seq[string]  # addresses hub dials proactively (Group A in Run A)

  PeerConfig* = object
    hubAddr*: string
    dialOut*: bool             # true = peer dials hub; false = peer listens, hub dials it
    reconnect*: ReconnectMode
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

proc parsePeerConfig*(): PeerConfig =
  result.hubAddr = getEnv("HUB_ADDR", "hub:5000")
  result.dialOut = getEnv("DIAL_OUT", "true").toLowerAscii() == "true"
  result.reconnect =
    if getEnv("RECONNECT", "none").toLowerAscii() == "aggressive":
      ReconnectAggressive
    else:
      ReconnectNone

  let privKeyHex = getEnv("PRIVATE_KEY", "")
  if privKeyHex.len > 0:
    try:
      let keyBytes = hexToSeqByte(privKeyHex)
      result.privateKey = Opt.some(PrivateKey.init(keyBytes).tryGet())
    except CatchableError as exc:
      warn "Invalid PRIVATE_KEY, using random key", error = exc.msg
