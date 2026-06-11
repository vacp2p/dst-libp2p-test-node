import chronicles
import chronos
import libp2p
import libp2p/protocols/ping
import libp2p_mix

export Ping   # so importers don't need to depend on libp2p/protocols/ping directly

# Mounts libp2p Ping on the switch and tells mix's exit layer how to read PingCodec.
# Peers can ping this node via mixProto.toConnection(dest, PingCodec, expectReply=true).
proc setup*(switch: Switch, mixProto: MixProtocol, rng: Rng): Ping {.raises: [LPError].} =
  let pingProto = Ping.new(rng = rng)
  switch.mount(pingProto)
  # 32 = libp2p ping nonce size (PingSize in libp2p/protocols/ping; not exported).
  mixProto.registerDestReadBehavior(PingCodec, readExactly(32))
  pingProto

# Every `intervalSecs` seconds, pings every peer in the mix nodePool via mix tunnels
# and logs RTT. Gives the "pure mixnet" (MIXENABLED=true, GOSSIPSUBMODE=off) mode a
# continuous traffic source so the mix path is exercised even without GossipSub.
proc periodicMixPing*(
    mixProto: MixProtocol, pingProto: Ping, intervalSecs: int = 30
) {.async: (raises: [CancelledError]).} =
  while true:
    let peerIds = mixProto.nodePool.peerIds()
    if peerIds.len == 0:
      warn "mix-ping skipped: empty nodePool"
    else:
      for targetPid in peerIds:
        let pubInfoOpt = mixProto.nodePool.get(targetPid)
        if pubInfoOpt.isNone:
          warn "mix-ping: peer missing from pool", target = $targetPid
          continue
        let pubInfo = pubInfoOpt.get()
        let conn = mixProto.toConnection(
          MixDestination.init(targetPid, pubInfo.multiAddr),
          PingCodec,
          MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
        ).valueOr:
          warn "mix-ping: toConnection failed", target = $targetPid, err = error
          continue
        try:
          let rtt = await pingProto.ping(conn)
          info "mix-ping ok", target = $targetPid, rtt = $rtt
        except CancelledError as e:
          raise e
        except CatchableError as e:
          warn "mix-ping failed", target = $targetPid, err = e.msg
        await sleepAsync(1.seconds)
    await sleepAsync(intervalSecs.seconds)
