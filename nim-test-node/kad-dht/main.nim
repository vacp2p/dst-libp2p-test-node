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

proc main {.async.} =
  randomize()

  var service = getEnv("SERVICE", "kad-service:5000")

  let
    rng = libp2p.newRng()
    (myId, muxer, address, nodeType, discovery) = getPeerDetails().valueOr:
      error "Error reading peer settings ",  err = error
      return

  var switch = buildSwitch(muxer, address)
  await switch.start()

  let selfId = switch.peerInfo.peerId
  notice "Node started", peerId = $selfId, role = nodeType, listen = address

  # Role-based execution
  case nodeType
  of RoleBootstrap:
    var kad = await mountDiscovery(switch, discovery, @[])
    discard await startHealthServer(prometheusPort)
    # Just stay alive and serve queries
    while true: await sleepAsync(1.hours)

  of RoleNormal:
    var bootAddressesRes = await connectToBootstraps(switch, muxer, service)
    let bootAddresses = bootAddressesRes.valueOr:
      error "Failed to discover bootstrap nodes", service = service, err = error
      quit(1)

    var kad = await mountDiscovery(switch, discovery, bootAddresses)
    await runWarmup(kad, selfId)
    discard await startHealthServer(prometheusPort)
    # Keep node alive for steady state refresh
    while true: await sleepAsync(1.hours)

  of RoleProbe:
    var bootAddressesRes = await connectToBootstraps(switch, muxer, service)
    let bootAddresses = bootAddressesRes.valueOr:
      error "Failed to discover bootstrap nodes", service = service, err = error
      quit(1)

    var kad = await mountDiscovery(switch, discovery, bootAddresses)
    await runProbe(kad)
    while true: await sleepAsync(1.hours)

waitFor(main())
