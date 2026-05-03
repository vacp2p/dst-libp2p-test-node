# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import
  chronos, chronos/unittest2/asynctests, results, stew/endians2, sequtils, chronicles
import lsquic
import ./helpers/[clientserver, param]

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

initializeLsquic(true, true)

const
  runs = if isFast(): 1 else: 10
  uploadSize = 100000 # 100KB
  downloadSize = 100000000 # 100MB
  chunkSize = 65536 # 64KB chunks like perf

proc runPerf(): Future[Duration] {.async.} =
  let address = initTAddress("127.0.0.1:12345")
  let client = makeClient()
  let server = makeServer()
  let listener = server.listen(address)
  let accepting = listener.accept()
  let dialing = client.dial(address)

  let outgoingConn = await dialing
  let incomingConn = await accepting

  let serverDone = newFuture[void]()
  let serverHandler = proc() {.async.} =
    let stream = await incomingConn.incomingStream()

    # Step 1: Read download size (8 bytes) 
    var sizeBuf = newSeq[byte](8)
    var sizeRead = 0
    while sizeRead < sizeBuf.len:
      let n = await stream.readOnce(sizeBuf[sizeRead].addr, sizeBuf.len - sizeRead)
      if n == 0:
        break
      sizeRead += n
    check sizeRead == 8
    let clientDownloadSize = sizeBuf
    check uint64.fromBytesBE(clientDownloadSize) == downloadSize.uint64

    # Step 2: Read upload data until EOF
    var totalBytesRead = 0
    var readBuf = newSeq[byte](chunkSize)
    while true:
      let n = await stream.readOnce(readBuf[0].addr, readBuf.len)
      if n == 0:
        break
      totalBytesRead += n
    check totalBytesRead == uploadSize

    # Step 3: Send download data back
    var remainingToSend = uint64.fromBytesBE(clientDownloadSize)
    while remainingToSend > 0:
      let toSend = min(remainingToSend, chunkSize)
      try:
        await stream.write(newSeq[byte](toSend))
      except StreamError:
        echo "unexpected stream error on server: ", getCurrentExceptionMsg()
        quit(1)

      remainingToSend -= toSend
    await stream.close()
    serverDone.complete()

  # Start server handler
  asyncSpawn serverHandler()

  let startTime = Moment.now()

  # Step 1: Send download size, activate stream first
  let clientStream = await outgoingConn.openStream()
  try:
    await clientStream.write(toSeq(downloadSize.uint64.toBytesBE()))
  except StreamError:
    echo "unexpected stream error on client: ", getCurrentExceptionMsg()
    quit(1)

  # Step 2: Send upload data in chunks
  var remainingToSend = uploadSize
  while remainingToSend > 0:
    let toSend = min(remainingToSend, chunkSize)
    try:
      let sending = newSeq[byte](toSend)
      await clientStream.write(sending)
    except StreamError:
      echo "unexpected stream error on client: ", getCurrentExceptionMsg()
      quit(1)
    remainingToSend -= toSend

  # Step 3: Close write side
  await clientStream.close()

  # Step 4: Start reading download data
  var totalDownloaded = 0
  # Reuse buffer for client-side download
  var downloadBuf = newSeq[byte](chunkSize)
  while totalDownloaded < downloadSize:
    let n = await clientStream.readOnce(downloadBuf[0].addr, downloadBuf.len)
    if n == 0:
      break
    totalDownloaded += n
  check totalDownloaded == downloadSize

  let duration = Moment.now() - startTime

  await serverDone

  await listener.stop()
  await client.stop()

  return duration

suite "perf protocol simulation":
  teardown:
    cleanupLsquic()

  asyncTest "test":
    var total: Duration

    echo "\nrunning perf with runs: ", $runs
    for i in 0 ..< runs:
      let duration = await runPerf()
      total += duration
      echo "\trun #" & $(i + 1) & " duration: " & $duration

    echo "\tavrg duration: " & $(total div runs)
