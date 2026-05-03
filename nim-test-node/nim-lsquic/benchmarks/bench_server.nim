# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Benchmark server for nim-lsquic.
## Handles two stream protocols:
##   MsgThroughput (0x01): read upload, send download
##   MsgLatency (0x02): echo ping/pong until EOF

import ./bench_common

proc handleThroughputStream(stream: Stream) {.async.} =
  # Read 8 bytes: upload size
  var uploadSizeBuf = newSeq[byte](8)
  var read = 0
  while read < 8:
    let n = await stream.readOnce(uploadSizeBuf[read].addr, 8 - read)
    if n == 0:
      return
    read += n

  # Read 8 bytes: download size
  var downloadSizeBuf = newSeq[byte](8)
  read = 0
  while read < 8:
    let n = await stream.readOnce(downloadSizeBuf[read].addr, 8 - read)
    if n == 0:
      return
    read += n

  let downloadSize = uint64.fromBytesBE(downloadSizeBuf)

  # Read all upload data until EOF
  var buf = newSeq[byte](DefaultChunkSize)
  while true:
    let n = await stream.readOnce(buf[0].addr, buf.len)
    if n == 0:
      break

  # Send download data
  let chunk = newSeq[byte](DefaultChunkSize)
  var remaining = downloadSize
  while remaining > 0:
    let toSend = min(remaining, DefaultChunkSize.uint64)
    try:
      await stream.write(chunk[0 ..< toSend.int])
    except StreamError:
      return
    remaining -= toSend

  await stream.close()

proc handleLatencyStream(stream: Stream) {.async.} =
  # Echo loop: read a 4-byte length-prefixed payload, send it back
  var lenBuf = newSeq[byte](4)
  while true:
    var read = 0
    while read < 4:
      let n = await stream.readOnce(lenBuf[read].addr, 4 - read)
      if n == 0:
        # Client closed
        await stream.close()
        return
      read += n

    let payloadLen = uint32.fromBytesBE(lenBuf).int
    if payloadLen == 0:
      continue

    # Read payload
    var payload = newSeq[byte](payloadLen)
    read = 0
    while read < payloadLen:
      let n = await stream.readOnce(payload[read].addr, payloadLen - read)
      if n == 0:
        await stream.close()
        return
      read += n

    # Echo back: length + payload
    try:
      await stream.write(lenBuf & payload)
    except StreamError:
      return

proc handleStream(stream: Stream) {.async.} =
  # First byte is the message type
  var typeBuf = newSeq[byte](1)
  let n = await stream.readOnce(typeBuf[0].addr, 1)
  if n == 0:
    return

  case typeBuf[0]
  of MsgThroughput:
    await handleThroughputStream(stream)
  of MsgLatency:
    await handleLatencyStream(stream)
  else:
    echo "Unknown message type: ", typeBuf[0]
    stream.abort()

proc handleConnection(conn: Connection) {.async.} =
  try:
    while true:
      let stream = await conn.incomingStream()
      asyncSpawn handleStream(stream)
  except ConnectionError:
    discard
  except CancelledError:
    discard

proc runServer(listenAddr: string, port: int) {.async.} =
  initializeLsquic(true, true)

  let server = makeServer()
  let address = initTAddress(listenAddr & ":" & $port)
  let listener = server.listen(address)

  echo "Benchmark server listening on ", listenAddr, ":", port

  try:
    while true:
      let conn = await listener.accept()
      asyncSpawn handleConnection(conn)
  except CancelledError:
    discard
  except TransportError:
    discard

  await listener.stop()
  cleanupLsquic()

when isMainModule:
  var listenAddr = "0.0.0.0"
  var port = DefaultPort

  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--listen", "-l":
      inc i
      listenAddr = paramStr(i)
    of "--port", "-p":
      inc i
      port = parseInt(paramStr(i))
    of "--help", "-h":
      echo "Usage: bench_server [--listen ADDR] [--port PORT]"
      echo "  --listen, -l  Listen address (default: 0.0.0.0)"
      echo "  --port, -p    Port (default: ", DefaultPort, ")"
      quit(0)
    else:
      echo "Unknown argument: ", arg
      quit(1)
    inc i

  waitFor runServer(listenAddr, port)
