import libp2p
import chronos
import chronicles
import libp2p/protocols/[kademlia, kad_disco]
import os
import env

# --- Helpers ---

proc getRandomPeerId*(): PeerId =
  # Generates a random peer ID for FIND_NODE targets
  let rng = newRng()
  return PeerId.init(PrivateKey.random(Secp256k1, rng[]).get()).get()

proc buildSwitch*(address: string): Switch =
  SwitchBuilder
    .new()
    .withNoise()
    .withRng(crypto.newRng())
    .withAddresses(@[MultiAddress.init(address).tryGet()])
    .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
    .withYamux()
    .build()

proc mountDiscovery*(switch: Switch, discovery: string, addresses: seq[(PeerId, seq[MultiAddress])]
  ): Future[KadDHT] {.async.}  =
  # Discovery selection
  if discovery == "kad-dht":
    let kad = KadDHT.new(
      switch,
      bootstrapNodes = addresses,
      config = KadDHTConfig.new(),
    )
    await kad.start()
    switch.mount(kad)
    return kad

  if discovery == "extended":
    let disco = KademliaDiscovery.new(
      switch,
      bootstrapNodes = addresses,
      config = KadDHTConfig.new(), # TODO check if this config is valid?
    )
    await disco.start()
    switch.mount(disco)
    return disco

  raise newException(ValueError, "Unknown DISCOVERY: " & discovery)


proc connectToBootstraps*(switch: Switch, muxer: string, service: string
  ): Future[Result[seq[(PeerId, seq[MultiAddress])], string]] {.async.} =
  let addrsRes = await resolveService(muxer, service)
  let addrs = addrsRes.valueOr:
    return err("Failed to resolve bootstrap service '" & service & "': " & error)
  info "Service resolved", service = addrs

  var bootstraps: seq[(PeerId, seq[MultiAddress])] = @[]
  var lastErr = ""

  for addr in addrs:
    try:
      let remotePeerId: PeerId = await switch.connect(addr, allowUnknownPeerId = true)
      notice "Connected to bootstrap", address = addr, peerId = remotePeerId
      bootstraps.add((remotePeerId, @[addr]))
    except CatchableError as exc:
      lastErr = exc.msg
      warn "Failed to connect to bootstrap", address = addr, error = exc.msg

  if bootstraps.len == 0:
    return err("Could not connect to any bootstrap resolved from '" & service &
               "' (candidates=" & $addrs.len & "). Last error: " & lastErr)

  ok(bootstraps)
