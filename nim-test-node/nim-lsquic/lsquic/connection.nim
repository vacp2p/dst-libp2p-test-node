# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronicles
import chronos
import ./[errors, stream, lsquic_ffi]
import ./context/context

type
  Connection* = ref object of RootObj
    local: TransportAddress
    remote: TransportAddress
    ensureClosedFut: Future[void]
    isClosed*: bool
    closed: AsyncEvent
    # Reuse a single closed-event waiter to minimize allocations on hot paths.
    closedWaiter: Future[void].Raising([CancelledError])
    quicContext: QuicContext
    quicConn: QuicConnection

  IncomingConnection = ref object of Connection

  OutgoingConnection = ref object of Connection

proc ensureClosed(connection: Connection) {.async: (raises: [CancelledError]).} =
  await connection.closedWaiter
  debug "Closing connection"
  connection.isClosed = true
  if not connection.quicConn.closedLocal:
    connection.quicConn.closedRemote = true

proc close*(conn: Connection) {.raises: [].} =
  if conn.isClosed:
    return
  conn.isClosed = true
  conn.quicConn.closedLocal = true
  conn.quicContext.close(conn.quicConn)

proc abort*(conn: Connection) {.gcsafe, raises: [].} =
  if conn.isClosed:
    return
  conn.isClosed = true
  conn.quicConn.closedLocal = true
  conn.quicContext.abort(conn.quicConn)

# TODO: refactor this into a single newConnection

proc newOutgoingConnection*(
    quicContext: QuicContext, local: TransportAddress, remote: TransportAddress
): OutgoingConnection =
  let closed = newAsyncEvent()
  let closedWaiter = closed.wait()
  let conn = OutgoingConnection(
    quicContext: quicContext,
    local: local,
    remote: remote,
    closed: closed,
    closedWaiter: closedWaiter,
  )
  conn.ensureClosedFut = conn.ensureClosed()
  conn

proc newIncomingConnection*(
    quicContext: QuicContext, quicConn: QuicConnection
): Connection =
  let closed = newAsyncEvent()
  let closedWaiter = closed.wait()
  let conn = IncomingConnection(
    quicContext: quicContext,
    quicConn: quicConn,
    closed: closed,
    closedWaiter: closedWaiter,
    local: quicConn.local,
    remote: quicConn.remote,
  )
  conn.ensureClosedFut = conn.ensureClosed()
  conn.quicConn.onClose = proc() {.raises: [].} =
    conn.closed.fire()
  conn

proc closedFuture*(connection: Connection): Future[void] {.raises: [].} =
  connection.ensureClosedFut

proc dial*(
    connection: OutgoingConnection
) {.async: (raw: true, raises: [CancelledError, DialError]).} =
  let retFut =
    Future[void].Raising([CancelledError, DialError]).init("OutgoingConnection.dial")
  let onClose = proc() {.raises: [].} =
    connection.closed.fire()

  connection.quicConn = connection.quicContext.dial(
    connection.local, connection.remote, retFut, onClose
  ).valueOr:
    retFut.fail(newException(DialError, "could not dial: " & error))
    nil
  retFut

proc incomingStream*(
    connection: Connection
): Future[Stream] {.async: (raises: [CancelledError, ConnectionError]).} =
  if connection.isClosed:
    raise newException(ConnectionClosedError, "connection closed")

  let incomingFut = connection.quicConn.incomingStream()
  let raceFut = await race(connection.closedWaiter, incomingFut)
  if raceFut == connection.closedWaiter:
    await incomingFut.cancelAndWait()
    raise newException(ConnectionClosedError, "connection closed")

  let stream = await incomingFut
  stream.doProcess = proc() {.gcsafe, raises: [].} =
    connection.quicContext.processWhenReady()
  stream

proc openStream*(
    connection: Connection
): Future[Stream] {.async: (raises: [CancelledError, ConnectionError]).} =
  if connection.isClosed:
    raise newException(ConnectionClosedError, "connection closed")

  let s = Stream.new()
  s.doProcess = proc() {.gcsafe, raises: [].} =
    connection.quicContext.processWhenReady()
  let created = connection.quicConn.addPendingStream(s)
  connection.quicContext.makeStream(connection.quicConn)
  connection.quicContext.processWhenReady()
  await created
  s

proc certificates*(conn: Connection): seq[seq[byte]] {.raises: [].} =
  conn.quicContext.certificates(conn.quicConn)

proc localAddress*(connection: Connection): TransportAddress {.raises: [].} =
  connection.local

proc remoteAddress*(connection: Connection): TransportAddress {.raises: [].} =
  connection.remote
