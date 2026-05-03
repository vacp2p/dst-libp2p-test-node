# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos, chronicles, results
import ./[errors, connection, tlsconfig, datagram, connectionmanager]
import ./context/[context, io, client]

type QuicClient* = ref object of RootObj
  connman: ConnectionManager
  tlsConfig: TLSConfig
  ctx4: ClientContext
  ctx6: ClientContext
  udp4: DatagramTransport
  udp6: DatagramTransport

proc new*(t: typedesc[QuicClient], tlsConfig: TLSConfig): QuicClient {.raises: [].} =
  QuicClient(tlsConfig: tlsConfig, connman: ConnectionManager.new())

proc createCtxUdp(
    tlsConfig: TLSConfig, family: AddressFamily
): (ClientContext, DatagramTransport) {.raises: [QuicError, TransportOsError].} =
  let ctx = ClientContext.new(tlsConfig).valueOr:
    raise newException(QuicError, error)

  proc onReceive(
      udp: DatagramTransport, remote: TransportAddress
  ) {.async: (raises: []).} =
    try:
      let datagram = Datagram(data: udp.getMessage())
      ctx.receive(datagram, udp.localAddress(), remote)
    except TransportError as e:
      error "Unexpected transport error", errorMsg = e.msg

  let udp =
    case family
    of AddressFamily.IPv4:
      newDatagramTransport(onReceive)
    of AddressFamily.IPv6:
      newDatagramTransport6(onReceive)
    else:
      raise newException(QuicError, "client supports only IPv4/IPv6 address")

  ctx.fd = cint(udp.fd)

  return (ctx, udp)

proc getCtxUdp(
    self: QuicClient, family: AddressFamily
): (ClientContext, DatagramTransport) {.raises: [QuicError, TransportOsError].} =
  case family
  of AddressFamily.IPv4:
    if self.udp4.isNil:
      let (ctx, udp) = createCtxUdp(self.tlsConfig, family)
      self.udp4 = udp
      self.ctx4 = ctx

    return (self.ctx4, self.udp4)
  of AddressFamily.IPv6:
    if self.udp6.isNil:
      let (ctx, udp) = createCtxUdp(self.tlsConfig, family)
      self.udp6 = udp
      self.ctx6 = ctx

    return (self.ctx6, self.udp6)
  else:
    raise newException(QuicError, "client supports only IPv4/IPv6 address")

proc dial*(
    self: QuicClient, address: TransportAddress
): Future[Connection] {.
    async: (raises: [CancelledError, QuicError, DialError, TransportOsError])
.} =
  let (ctx, udp) = self.getCtxUdp(address.family)
  let connection = newOutgoingConnection(ctx, udp.localAddress, address)
  self.connman.addConnection(connection)
  await connection.dial()
  connection

proc stop*(self: QuicClient) {.async: (raises: [CancelledError]).} =
  await noCancel self.connman.stop()
  # Politely wait before closing udp so connections closure go out
  # TODO: this should be ~ 3 times the PTO.
  # Find out if it's possible to react to shutting down the context and
  # lsquic engine. Maybe there's a callback that one can hook to and safely
  # stop the udp transport.
  await noCancel sleepAsync(300.milliseconds)
  if not self.ctx4.isNil:
    self.ctx4.stop()
  if not self.ctx6.isNil:
    self.ctx6.stop()
  if not self.udp4.isNil:
    await noCancel self.udp4.closeWait()
  if not self.ctx4.isNil:
    self.ctx4.destroy()
  if not self.udp6.isNil:
    await noCancel self.udp6.closeWait()
  if not self.ctx6.isNil:
    self.ctx6.destroy()
