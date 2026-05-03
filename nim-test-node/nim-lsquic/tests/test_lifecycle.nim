# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sets
import chronos, chronos/unittest2/asynctests, results, chronicles
import lsquic
import lsquic/[datagram]
import lsquic/context/[client, context, io]
import ./helpers/[certificate, clientserver, stream]

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

initializeLsquic(true, true)

type ConnectedPeers =
  tuple[
    client: QuicClient, listener: Listener, outgoing: Connection, incoming: Connection
  ]

proc connectPeers(): Future[ConnectedPeers] {.async.} =
  let client = makeClient()
  let server = makeServer()
  let listener = server.listen(initTAddress("127.0.0.1:0"))
  let accepting = listener.accept()
  let outgoing = await client.dial(listener.localAddress())
  let incoming = await accepting

  (client, listener, outgoing, incoming)

proc stopPeers(peers: ConnectedPeers) {.async.} =
  if not peers.outgoing.isNil:
    peers.outgoing.close()
  if not peers.incoming.isNil:
    peers.incoming.close()
  await allFutures(peers.client.stop(), peers.listener.stop())

suite "lifecycle":
  teardown:
    cleanupLsquic()

  asyncTest "listener stop makes accept fail":
    let server = makeServer()
    let listener = server.listen(initTAddress("127.0.0.1:0"))
    let accepting = listener.accept()

    await listener.stop()

    expect TransportError:
      discard await accepting

  asyncTest "listener stop fails all pending accepts":
    let server = makeServer()
    let listener = server.listen(initTAddress("127.0.0.1:0"))
    let accepting1 = listener.accept()
    let accepting2 = listener.accept()
    let accepting3 = listener.accept()

    await listener.stop()

    expect TransportError:
      discard await accepting1
    expect TransportError:
      discard await accepting2
    expect TransportError:
      discard await accepting3

  asyncTest "connection close propagates to peer":
    let peers = await connectPeers()
    defer:
      await stopPeers(peers)

    peers.outgoing.close()

    check (await peers.outgoing.closedFuture().withTimeout(2.seconds))
    check (await peers.incoming.closedFuture().withTimeout(2.seconds))
    check peers.incoming.isClosed

  asyncTest "client stop closes active connections":
    let peers = await connectPeers()

    await peers.client.stop()

    check (await peers.outgoing.closedFuture().withTimeout(2.seconds))
    check (await peers.incoming.closedFuture().withTimeout(2.seconds))

    peers.incoming.close()
    await peers.listener.stop()

  asyncTest "operations fail after connection close":
    let peers = await connectPeers()
    defer:
      await stopPeers(peers)

    peers.outgoing.close()
    check (await peers.outgoing.closedFuture().withTimeout(2.seconds))
    check (await peers.incoming.closedFuture().withTimeout(2.seconds))

    expect ConnectionClosedError:
      discard await peers.outgoing.openStream()

    expect ConnectionClosedError:
      discard await peers.incoming.incomingStream()

  asyncTest "abort wakes pending incoming stream":
    let peers = await connectPeers()
    defer:
      await stopPeers(peers)

    let incomingWaiting = peers.incoming.incomingStream()
    await sleepAsync(100.milliseconds)
    peers.outgoing.abort()

    expect ConnectionClosedError:
      discard await incomingWaiting

  asyncTest "cancel pending outgoing streams clears queue":
    let quicConn = QuicConnection(incoming: newAsyncQueue[Stream]())
    let stream1 = Stream.new()
    let stream2 = Stream.new()
    let pending1 = quicConn.addPendingStream(stream1)
    let pending2 = quicConn.addPendingStream(stream2)

    quicConn.cancelPending()

    expect ConnectionError:
      await pending1
    expect ConnectionError:
      await pending2
    check quicConn.popPendingStream(nil).isNone()

  asyncTest "abort after open stream still closes connection":
    let peers = await connectPeers()
    defer:
      await stopPeers(peers)

    let opening = peers.outgoing.openStream()
    peers.outgoing.abort()
    check (await opening.withTimeout(2.seconds))
    let stream = await opening
    check (await peers.outgoing.closedFuture().withTimeout(2.seconds))

    expect StreamError:
      await stream.write(@[1'u8])

  asyncTest "write after close raises stream error":
    let peers = await connectPeers()
    defer:
      await stopPeers(peers)

    let outgoingStream = await peers.outgoing.openStream()
    await outgoingStream.write(@[1'u8])
    let incomingStream = await peers.incoming.incomingStream()
    var kickoff = newSeq[byte](1)
    check (await incomingStream.readOnce(kickoff)) == 1
    check kickoff[0] == 1

    await outgoingStream.close()

    expect StreamError:
      await outgoingStream.write(@[1'u8])

    var buf = newSeq[byte](8)
    check (await incomingStream.readOnce(buf)) == 0
    await incomingStream.close()

  asyncTest "read once returns zero repeatedly after eof":
    let peers = await connectPeers()
    defer:
      await stopPeers(peers)

    let outgoingStream = await peers.outgoing.openStream()
    await outgoingStream.write(@[9'u8, 8, 7, 6])
    let incomingStream = await peers.incoming.incomingStream()
    await outgoingStream.close()

    check (await incomingStream.readStreamTillEOF()) == @[9'u8, 8, 7, 6]

    var buf = newSeq[byte](8)
    check (await incomingStream.readOnce(buf)) == 0
    check (await incomingStream.readOnce(buf)) == 0
    await incomingStream.close()

  asyncTest "blocked read completes when peer half closes":
    let peers = await connectPeers()
    defer:
      await stopPeers(peers)

    let outgoingStream = await peers.outgoing.openStream()
    await outgoingStream.write(@[42'u8])
    let incomingStream = await peers.incoming.incomingStream()
    var firstChunk = newSeq[byte](1)
    check (await incomingStream.readOnce(firstChunk)) == 1
    check firstChunk[0] == 42

    var buf = newSeq[byte](8)
    let reading = incomingStream.readOnce(buf)

    await sleepAsync(100.milliseconds)
    check not reading.finished

    await outgoingStream.close()

    check (await reading.withTimeout(2.seconds))
    check (await reading) == 0
    await incomingStream.close()

  asyncTest "peer reset":
    let peers = await connectPeers()
    defer:
      await stopPeers(peers)

    let outgoingStream = await peers.outgoing.openStream()
    await outgoingStream.write(@[1'u8])
    let incomingStream = await peers.incoming.incomingStream()

    var firstByte = newSeq[byte](1)
    check (await incomingStream.readOnce(firstByte)) == 1
    check firstByte[0] == 1

    var buf = newSeq[byte](8)
    let reading = incomingStream.readOnce(buf)

    await sleepAsync(100.milliseconds)
    outgoingStream.abort()

    check (await reading.withTimeout(2.seconds))
    check (await reading) == 0
    check incomingStream.isEof

    var isReset = false
    try:
      await incomingStream.write(@[2'u8])
    except StreamResetError as exc:
      isReset = true
      check exc.how == ResetWrite

    check isReset

  asyncTest "zero length reads return zero":
    let stream = Stream.new()
    var empty: seq[byte] = @[]

    check (await stream.readOnce(empty)) == 0

  asyncTest "late datagrams are ignored after context stops":
    let verifier: CertificateVerifier = CustomCertificateVerifier.init(
      proc(serverName: string, derCertificates: seq[seq[byte]]): bool {.gcsafe.} =
        discard serverName
        derCertificates.len > 0
    )
    let tlsConfig = TLSConfig.new(
      testCertificate(), testPrivateKey(), @["test"].toHashSet(), Opt.some(verifier)
    )
    let ctx = ClientContext.new(tlsConfig).valueOr:
      raiseAssert error
    let local = initTAddress("127.0.0.1:12345")
    let remote = initTAddress("127.0.0.1:54321")

    ctx.stop()
    ctx.receive(Datagram(data: @[1'u8, 2, 3]), local, remote)
    ctx.processWhenReady()

    ctx.destroy()
    ctx.receive(Datagram(data: @[4'u8, 5, 6]), local, remote)
    ctx.processWhenReady()
