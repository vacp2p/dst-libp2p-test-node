# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos, chronicles, results
import ./[errors, connection, tlsconfig, datagram, connectionmanager]
import ./context/[server, context, io]

type QuicServer* = ref object of RootObj
  tlsConfig: TLSConfig

proc new*(
    t: typedesc[QuicServer], tlsConfig: TLSConfig
): QuicServer {.raises: [QuicConfigError].} =
  if tlsConfig.certificate.len == 0:
    raise newException(QuicConfigError, "tlsConfig does not contain a certificate")

  return QuicServer(tlsConfig: tlsConfig)

type Listener* = ref object of RootObj
  quicContext: ServerContext
  connman: ConnectionManager
  udp: DatagramTransport

proc newListener*(
    tlsConfig: TLSConfig, address: TransportAddress
): Result[Listener, string] =
  let quicContext = ?ServerContext.new(tlsConfig)

  proc onReceive(
      udp: DatagramTransport, remote: TransportAddress
  ) {.async: (raises: []).} =
    try:
      let datagram = Datagram(data: udp.getMessage())
      quicContext.receive(datagram, udp.localAddress(), remote)
    except TransportError as e:
      error "Unexpected transport error", errorMsg = e.msg

  var udp: DatagramTransport
  case address.family
  of AddressFamily.IPv4:
    udp = newDatagramTransport(onReceive, local = address)
  of AddressFamily.IPv6:
    udp = newDatagramTransport6(onReceive, local = address)
  else:
    return err("only IPv4/IPv6 address is supported")

  let listener =
    Listener(quicContext: quicContext, connman: ConnectionManager.new(), udp: udp)
  quicContext.fd = cint(listener.udp.fd)

  ok(listener)

proc waitForIncoming(
    listener: Listener
): Future[QuicConnection] {.async: (raises: [CancelledError]).} =
  await listener.quicContext.incoming.get()

proc accept*(
    listener: Listener
): Future[Connection] {.async: (raises: [CancelledError, TransportError]).} =
  let
    incomingFut = listener.waitForIncoming()
    closedFut = listener.connman.closed
    raceFut = await race(closedFut, incomingFut)

  if raceFut == closedFut:
    await incomingFut.cancelAndWait()
    raise newException(TransportError, "listener is stopped")

  let quicConn = await incomingFut
  let conn = newIncomingConnection(listener.quicContext, quicConn)
  listener.connman.addConnection(conn)
  conn

proc localAddress*(
    listener: Listener
): TransportAddress {.raises: [TransportOsError].} =
  listener.udp.localAddress()

proc stop*(listener: Listener) {.async: (raises: [CancelledError]).} =
  await noCancel listener.connman.stop()
  # Politely wait before closing udp so connections closure go out
  # TODO: this should be ~ 3 times the PTO.
  # Find out if it's possible to react to shutting down the context and
  # lsquic engine. Maybe there's a callback that one can hook to and safely
  # stop the udp transport.
  await noCancel sleepAsync(300.milliseconds)
  listener.quicContext.stop()
  await noCancel listener.udp.closeWait()
  listener.quicContext.destroy()

proc listen*(
    self: QuicServer, address: TransportAddress
): Listener {.raises: [QuicError, TransportOsError].} =
  newListener(self.tlsConfig, address).valueOr:
    raise newException(QuicError, error)
