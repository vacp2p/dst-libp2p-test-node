import os, strutils

import libp2p
import libp2p/[crypto/secp, multiaddress, muxers/mplex/lpchannel]
import libp2p/protocols/kademlia
import libp2p/protocols/ping

import kad_utils

proc buildSwitch*(muxer: string, address: string): Switch =
  var builder = SwitchBuilder
    .new()
    .withNoise()
    .withAddress(MultiAddress.init(address).tryGet())
    .withMaxConnections(parseInt(getEnv("MAXCONNECTIONS", "250")))

  case muxer.toLowerAscii()
  of "quic":
    builder = builder.withQuicTransport()
  of "yamux":
    builder = builder.withTcpTransport(flags = {ServerFlags.TcpNoDelay})
              .withYamux()
  of "mplex":
    builder = builder.withTcpTransport(flags = {ServerFlags.TcpNoDelay})
              .withMplex()
  else:
    raiseAssert("Unknown muxer type: " & muxer)

  return builder.build()

proc mountBaseProtocols*(switch: Switch, rng: Rng): tuple[ping: Ping, kad: KadDHT] =
  ## Mount protocols shared by normal and bootstrap nodes before switch.start().
  let pingProtocol = Ping.new(rng = rng)
  switch.mount(pingProtocol)
  let kad = mountKadDht(switch, rng)
  return (pingProtocol, kad)
