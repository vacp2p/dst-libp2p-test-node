# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, chronos/unittest2/asynctests, results, chronicles
import lsquic
import ./helpers/clientserver

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

initializeLsquic(true, true)

proc runConnectionTest(
    listenAddress: TransportAddress, dialAddress: TransportAddress
) {.async.} =
  let client = makeClient()
  let server = makeServer()
  let listener = server.listen(listenAddress)
  let boundAddress = listener.localAddress()
  defer:
    await allFutures(client.stop(), listener.stop())
  let accepting = listener.accept()
  let dialing = client.dial(dialAddress)

  let outgoingConn = await dialing
  let incomingConn = await accepting

  check:
    outgoingConn.certificates().len == 1
    incomingConn.certificates().len == 1
    outgoingConn.remoteAddress().family == dialAddress.family
    outgoingConn.remoteAddress().port == dialAddress.port
    incomingConn.localAddress().family == boundAddress.family
    incomingConn.localAddress().port == boundAddress.port
    outgoingConn.localAddress().port == incomingConn.remoteAddress().port

  echo "Connected!"

  let outgoingBehaviour = proc() {.async.} =
    let stream = await outgoingConn.openStream()

    await stream.write(@[1'u8, 2, 3, 4, 5])
    await stream.write(@[6'u8, 7, 8, 9, 10])

    echo "Closing client stream"

    echo "Client closed"
    await stream.close()

    #echo "Client aborted"
    # stream.abort() # Not interested in RW anything else

  let incomingBehaviour = proc() {.async.} =
    try:
      let stream = await incomingConn.incomingStream()
      echo "Received stream in server"

      var buf = newSeq[byte](16)
      var received: seq[byte]
      while true:
        let n = await stream.readOnce(buf)
        if n == 0:
          break
        received.add(buf[0 ..< n])

      check:
        received == @[1'u8, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        stream.isEof

      let eofRead = await stream.readOnce(buf)
      check eofRead == 0

      echo "Server closed"
      await stream.close()

      #echo "Server aborted"
      #stream.abort() # Not interested in RW anything else
    except StreamError:
      raiseAssert "Stream error: " & getCurrentExceptionMsg()
    except CancelledError:
      raiseAssert "Canceled incoming behavior"

  discard allFutures(outgoingBehaviour(), incomingBehaviour())

  await sleepAsync(1.seconds)

  outgoingConn.close()
  incomingConn.close()

  # Cannot create a stream once closed
  expect ConnectionClosedError:
    discard await outgoingConn.openStream()

  await sleepAsync(1.seconds)

proc runConnectionTest(address: TransportAddress) {.async.} =
  await runConnectionTest(address, address)

proc runConcurrentStreamOpenTest(address: TransportAddress) {.async.} =
  const streamCount = 16

  let client = makeClient()
  let server = makeServer()
  let listener = server.listen(address)
  defer:
    await allFutures(client.stop(), listener.stop())

  let accepting = listener.accept()
  let dialing = client.dial(address)

  let outgoingConn = await dialing
  let incomingConn = await accepting

  var received = newSeq[bool](streamCount)

  let receiveAll = proc() {.async.} =
    for _ in 0 ..< streamCount:
      let stream = await incomingConn.incomingStream()
      var id: array[1, byte]
      let n = await stream.readOnce(id[0].addr, id.len)
      check n == 1
      check id[0].int < streamCount
      received[id[0].int] = true
      await stream.close()

  var sendAll: seq[Future[void]]
  for i in 0 ..< streamCount:
    sendAll.add(
      (
        proc(idx: int): Future[void] {.async.} =
          let stream = await outgoingConn.openStream()
          await stream.write(@[byte(idx)])
          await stream.close()
      )(i)
    )

  await allFutures(receiveAll(), allFutures(sendAll))

  for seen in received:
    check seen

suite "connection":
  teardown:
    cleanupLsquic()

  asyncTest "ipv4":
    await runConnectionTest(initTAddress("127.0.0.1:12345"))

  asyncTest "ipv6":
    await runConnectionTest(initTAddress("[::1]:12345"))

  asyncTest "ipv6 dual-stack listener accepts ipv4 dial":
    await runConnectionTest(initTAddress("[::]:12347"), initTAddress("127.0.0.1:12347"))

  asyncTest "multiple concurrent stream opens":
    await runConcurrentStreamOpenTest(initTAddress("127.0.0.1:12346"))
