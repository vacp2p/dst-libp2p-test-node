# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, chronos/unittest2/asynctests, results, chronicles
import lsquic
import ./helpers/[clientserver, param, stream]

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

initializeLsquic(true, true)

const
  SequentialRounds = if isFast(): 2 else: 5
  StreamsPerRound = if isFast(): 2 else: 3
  ConcurrentClients = if isFast(): 2 else: 4
  LargeWriteSize =
    if isFast():
      512 * 1024
    else:
      2 * 1024 * 1024
  ConcurrentWriteChunks = if isFast(): 4 else: 8
  ConcurrentWriteChunkSize =
    if isFast():
      16 * 1024
    else:
      64 * 1024

proc payload(id: int, size: int): seq[byte] =
  result = newSeq[byte](size)
  result[0] = byte(id)
  for i in 1 ..< size:
    result[i] = byte((id + i) mod 251)

proc connectPeers(): Future[(QuicClient, Listener, Connection, Connection)] {.async.} =
  let client = makeClient()
  let server = makeServer()
  let listener = server.listen(initTAddress("127.0.0.1:0"))
  let accepting = listener.accept()
  let outgoing = await client.dial(listener.localAddress())
  let incoming = await accepting

  (client, listener, outgoing, incoming)

proc runSequentialRound(round: int) {.async.} =
  let client = makeClient()
  let server = makeServer()
  let listener = server.listen(initTAddress("127.0.0.1:0"))
  defer:
    await allFutures(client.stop(), listener.stop())

  let accepting = listener.accept()
  let outgoing = await client.dial(listener.localAddress())
  let incoming = await accepting

  for streamId in 0 ..< StreamsPerRound:
    let sent = payload(round * 10 + streamId, 128 + streamId * 37)
    let outgoingStream = await outgoing.openStream()

    await outgoingStream.write(sent)
    let incomingStream = await incoming.incomingStream()
    await outgoingStream.close()

    check (await incomingStream.readStreamTillEOF()) == sent
    await incomingStream.close()

  outgoing.close()
  check (await outgoing.closedFuture().withTimeout(2.seconds))
  check (await incoming.closedFuture().withTimeout(2.seconds))

suite "stress":
  teardown:
    cleanupLsquic()

  asyncTest "repeated connect and transfer":
    for round in 0 ..< SequentialRounds:
      await runSequentialRound(round)

  asyncTest "large single write roundtrip":
    let (client, listener, outgoing, incoming) = await connectPeers()
    defer:
      outgoing.close()
      incoming.close()
      await allFutures(client.stop(), listener.stop())

    let sent = payload(99, LargeWriteSize)
    let outgoingStream = await outgoing.openStream()
    let writing = outgoingStream.write(sent)
    let incomingStream = await incoming.incomingStream()
    let reading = incomingStream.readStreamTillEOF()

    await writing
    await outgoingStream.close()

    check (await reading) == sent
    await incomingStream.close()

  asyncTest "concurrent writes on one stream preserve chunk boundaries":
    let (client, listener, outgoing, incoming) = await connectPeers()
    defer:
      outgoing.close()
      incoming.close()
      await allFutures(client.stop(), listener.stop())

    let outgoingStream = await outgoing.openStream()
    var writes: seq[Future[void]]
    for chunkId in 0 ..< ConcurrentWriteChunks:
      writes.add(outgoingStream.write(payload(chunkId, ConcurrentWriteChunkSize)))

    let incomingStream = await incoming.incomingStream()
    let reading = incomingStream.readStreamTillEOF()

    await allFutures(writes)
    await outgoingStream.close()

    let received = await reading
    check received.len == ConcurrentWriteChunks * ConcurrentWriteChunkSize

    var seen = newSeq[bool](ConcurrentWriteChunks)
    for offset in countup(0, received.high, ConcurrentWriteChunkSize):
      let chunkId = received[offset].int
      check chunkId >= 0
      check chunkId < ConcurrentWriteChunks
      check not seen[chunkId]
      check received[offset ..< offset + ConcurrentWriteChunkSize] ==
        payload(chunkId, ConcurrentWriteChunkSize)
      seen[chunkId] = true

    for wasSeen in seen:
      check wasSeen

    await incomingStream.close()

  asyncTest "multiple concurrent clients":
    let server = makeServer()
    let listener = server.listen(initTAddress("127.0.0.1:0"))
    let address = listener.localAddress()
    defer:
      await listener.stop()

    var received = newSeq[bool](ConcurrentClients)

    let serverTask = proc() {.async.} =
      var handlers: seq[Future[void]]
      for _ in 0 ..< ConcurrentClients:
        let incoming = await listener.accept()
        handlers.add(
          (
            proc(conn: Connection): Future[void] {.async.} =
              let stream = await conn.incomingStream()
              let got = await stream.readStreamTillEOF()
              check got.len >= 1
              check got[0].int < ConcurrentClients
              received[got[0].int] = true
              await stream.write(@[got[0]])
              await stream.close()
              conn.close()
              check (await conn.closedFuture().withTimeout(2.seconds))
          )(incoming)
        )

      await allFutures(handlers)

    let clientTask = proc(id: int): Future[void] {.async.} =
      let client = makeClient()
      defer:
        await client.stop()

      let conn = await client.dial(address)
      let stream = await conn.openStream()
      let sent = payload(id, 256)

      await stream.write(sent)
      await stream.close()

      var ack = newSeq[byte](1)
      check (await stream.readOnce(ack)) == 1
      check ack[0] == byte(id)
      check (await stream.readOnce(ack)) == 0
      conn.close()
      check (await conn.closedFuture().withTimeout(2.seconds))

    var clients: seq[Future[void]]
    for id in 0 ..< ConcurrentClients:
      clients.add(clientTask(id))

    await allFutures(serverTask(), allFutures(clients))

    for seen in received:
      check seen
