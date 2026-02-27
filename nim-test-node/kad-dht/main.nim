import stew/endians2, stew/byteutils, tables, strutils, os, json
import chronos, chronos/apps/http/httpserver
import env
import std/[strformat, random, hashes]
import libp2p, libp2p/[muxers/mplex/lpchannel, stream/connection, crypto/secp, multiaddress]
import libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]
import libp2p/protocols/[kademlia, kad_disco]

import sequtils, math, metrics, metrics/chronos_httpserver
from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname
import helpers
import core

  # 15x FIND_NODE(random)
  for i in 1..15:
    let target = getRandomPeerId()
    debug "Warmup: Finding random node", iteration = i, target = target

    let peers = await kad.findNode(target.toKey())
    logFindNodeResult("warmup-random", target, peers)

    await sleepAsync(2.seconds)

  notice "Warmup complete"

proc resolveAddress(muxer: string, tAddress: string): Future[Result[seq[MultiAddress], string]] {.async.} =
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

proc resolveService(muxer: string, service: string): Future[Result[seq[MultiAddress], string]] {.async.} =
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


proc connectToBootstraps(switch: Switch, muxer: string, service: string) {.async.} =
  let addrsRes = await resolveService(muxer, service)
  let addrs = addrsRes.valueOr:
    error "Failed to resolve bootstrap service", service = service, error = error
    return

  for addr in addrs:
    try:
      discard await switch.connect(addr, allowUnknownPeerId=true)
      notice "Connected to bootstrap", address = addr
      await sleepAsync(2.seconds)
    except CatchableError as exc:
      warn "Failed to connect to bootstrap", address = addr, error = exc.msg


proc runProbe(kad: KadDHT) {.async.} =
  notice "Starting probe loop"
  while true:
    let
      targetPeer = getRandomPeerId()
      targetKey = targetPeer.toKey()
      start = getTime()

    try:
      let peers = await kad.findNode(targetKey).wait(30.seconds)
      let duration = (getTime() - start).inMilliseconds()
      notice "Probe Result",
        target = $targetPeer,
        success = true,
        duration_ms = duration,
        peers_found = peers.len,
        closer_peers = peers.mapIt($it)

    except CatchableError as exc:
      let duration = (getTime() - start).inMilliseconds()
      warn "Probe Failed",
        target = $targetPeer,
        success = false,
        duration_ms = duration,
        error = exc.msg

    await sleepAsync(10.seconds)


proc main {.async.} =
  randomize()

  var service = getEnv("SERVICE", "kad-service:5000")

  let
    rng = libp2p.newRng()
    (myId, muxer, address, nodeType, discovery) = getPeerDetails().valueOr:
      error "Error reading peer settings ",  err = error
      return

  var switch = buildSwitch(address)
  var kad = mountDiscovery(switch, discovery)

  await switch.start()

  let selfId = switch.peerInfo.peerId
  notice "Node started", peerId = $selfId, role = nodeType, listen = address

  # Role-based execution
  case nodeType
  of RoleBootstrap:
    # Just stay alive and serve queries
    while true: await sleepAsync(1.hours)

  of RoleNormal:
    await connectToBootstraps(switch, muxer, service)
    await runWarmup(kad, selfId)
    # Keep node alive for steady state refresh
    while true: await sleepAsync(1.hours)

  of RoleProbe:
    await connectToBootstraps(switch, muxer, service)
    await runProbe(kad)
    while true: await sleepAsync(1.hours)

waitFor(main())
