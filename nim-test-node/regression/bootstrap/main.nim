import chronos
import chronicles
import metrics
import metrics/chronos_httpserver

import libp2p

import ../env
import ../node_setup
import ../shutdown_utils

logScope:
  topics = "dst"

proc main {.async.} =
  let
    rng = libp2p.newRng()
    (myId, muxer, _, address) =
      getPeerDetails().valueOr:
        error "Node configuration is invalid", error = error
        quit(1)

  let switch = buildSwitch(muxer, address)
  discard mountBaseProtocols(switch, rng)

  await switch.start()

  info "Starting metrics server"
  let metricsServer = await startMetricsServer(parseIpAddress("0.0.0.0"), prometheusPort)
  if metricsServer.isErr:
    warn "Failed to initialize metrics server", error = metricsServer.error
  elif inShadow:
    asyncSpawn storeMetrics(myId)

  info "Listening on ", address = switch.peerInfo.addrs
  info "Peer details ", peer = myId, peerId = switch.peerInfo.peerId
  info "Node started",
    nodeType = "bootstrap",
    peer = myId,
    peerId = switch.peerInfo.peerId,
    listen = switch.peerInfo.addrs

  await waitShutdownSignal()

waitFor(main())
