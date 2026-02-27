import libp2p
import chronos
import chronicles
import libp2p/protocols/[kademlia, kad_disco]
import os

# --- Helpers ---

proc getRandomPeerId*(): PeerId =
  # Generates a random peer ID for FIND_NODE targets
  let rng = newRng()
  return PeerId.init(PrivateKey.random(Secp256k1, rng[]).get()).get()

proc logFindNodeResult*(tag: string, target: PeerId, peers: seq[PeerId]) =
  debug "findNode result", tag = tag, target = $target, count = peers.len
  for i, p in peers:
    debug "findNode peer", tag = tag, i = i, peer = $p

proc buildSwitch*(address: string): Switch =
  SwitchBuilder
    .new()
    .withNoise()
    .withRng(crypto.newRng())
    .withAddresses(@[MultiAddress.init(address).tryGet()])
    .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
    .withYamux()
    .build()

proc mountDiscovery*(switch: Switch, discovery: string): KadDHT =
  # 1) Common bootstrap nodes config
  let isBootstrap = getEnv("NODE_ROLE") == "RoleBootstrap"

  var bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[]
  if not isBootstrap:
    let bootstrapPeerIdStr = getEnv("BOOTSTRAP_PEER_ID", "")
    let bootstrapAddrStr = getEnv("BOOTSTRAP_ADDR", "")

    let otherPeerId = PeerId.init(bootstrapPeerIdStr).tryGet()
    let otherAddr = MultiAddress.init(bootstrapAddrStr).tryGet()

    bootstrapNodes = @[(otherPeerId, @[otherAddr])]

  # 2) Discovery selection
  if discovery == "kad-dht":
    let kad = KadDHT.new(
      switch,
      bootstrapNodes = bootstrapNodes,
      config = KadDHTConfig.new(),
    )
    switch.mount(kad)
    return kad

  if discovery == "extended":
    let disco = KademliaDiscovery.new(
      switch,
      bootstrapNodes = bootstrapNodes,
      config = KadDHTConfig.new(), # TODO check if this config is valid?
    )
    switch.mount(disco)
    return disco

  raise newException(ValueError, "Unknown DISCOVERY: " & discovery)
