# Test to debug pacing delays
# Run with: nim c -r tests/test_pacing_debug.nim
#
# IMPORTANT: This test requires pacing to be ENABLED in the lsquic library.
# Before running, temporarily modify these files:
#   lsquic/context/server.nim: set es_pace_packets = 1
#   lsquic/context/client.nim: set es_pace_packets = 1

{.used.}

import std/[times, strformat, strutils, monotimes]
import chronos, chronos/unittest2/asynctests, results, chronicles
import lsquic
import lsquic/lsquic_ffi
import ./helpers/clientserver

trace "chronicles tracing"

# LSQUIC logger callback - prints pacer-related logs
proc logCallback(ctx: pointer, buf: cstring, len: csize_t): cint {.cdecl.} =
  let msg = ($buf).strip()
  # Print ALL lsquic messages to see what's happening
  # Filter for pacer-related messages - check the actual module prefixes
  if "pacer" in msg.toLowerAscii or "token" in msg.toLowerAscii or 
     "next_sched" in msg.toLowerAscii or "send_ctl" in msg.toLowerAscii or
     "can_send" in msg.toLowerAscii or "cwnd" in msg.toLowerAscii or
     "pace" in msg.toLowerAscii or "srtt" in msg.toLowerAscii:
    echo "[LSQUIC] ", msg
  return 0  # Return cint

var loggerIf: struct_lsquic_logger_if

proc enablePacerLogging() =
  loggerIf.log_buf = logCallback
  lsquic_logger_init(addr loggerIf, nil, LLTS_HHMMSSMS)
  # Enable debug logging for relevant modules
  discard lsquic_logger_lopt("pacer=debug")
  discard lsquic_logger_lopt("sendctl=debug")
  discard lsquic_logger_lopt("cfcw=debug")  # congestion flow control window
  discard lsquic_logger_lopt("conn=debug")  # connection level
  echo "=== LSQUIC Pacer Debug Logging Enabled ==="

suite "Pacing Debug":
  setup:
    initializeLsquic(true, true)
    enablePacerLogging()

  asyncTest "measure pacing delays with burst of messages":
    echo ""
    echo "=== Test: Burst of messages with pacing ==="
    echo "NOTE: Make sure es_pace_packets=1 in client.nim and server.nim!"
    echo ""
    
    let address = initTAddress("127.0.0.1:19876")
    
    # Use the standard client/server makers - they will use current settings
    let client = makeClient()
    let server = makeServer()
    let listener = server.listen(address)
    let boundAddress = listener.localAddress()
    
    defer:
      await allFutures(client.stop(), listener.stop())
    
    # Connect
    let accepting = listener.accept()
    let dialing = client.dial(boundAddress)
    
    let outgoingConn = await dialing
    let incomingConn = await accepting
    echo "Connected!"
    
    # Server: receive data in background
    let serverTask = proc() {.async.} =
      let stream = await incomingConn.incomingStream()
      var buf = newSeq[byte](2000)
      var totalReceived = 0
      while totalReceived < 20000:  # Expect 20 x 1000 byte messages
        let n = await stream.readOnce(buf)
        if n == 0:
          break
        totalReceived += n
      echo fmt"Server received total: {totalReceived} bytes"
      await stream.close()
    
    asyncSpawn serverTask()
    
    # Client: send burst of messages
    let stream = await outgoingConn.openStream()
    echo "Stream opened, sending 20 messages of 1KB each..."
    echo ""
    
    let msgSize = 1000
    let msg = newSeq[byte](msgSize)
    
    var maxDelay = 0'i64
    var totalDelay = 0'i64
    
    for i in 1..20:
      let startTime = getMonoTime()
      await stream.write(msg)
      let endTime = getMonoTime()
      let delayUs = (endTime - startTime).inMicroseconds
      let delayMs = delayUs div 1000
      totalDelay += delayUs
      if delayUs > maxDelay:
        maxDelay = delayUs
      
      if delayMs > 5:
        echo fmt"  Message {i}: {delayMs}ms <<< DELAY!"
      else:
        echo fmt"  Message {i}: {delayUs}us"
    
    echo ""
    echo fmt"=== Results: max={maxDelay div 1000}ms, avg={totalDelay div 20 div 1000}ms ==="
    echo ""
    
    await stream.close()
    await sleepAsync(500)
    
    outgoingConn.close()
    incomingConn.close()
    
    await sleepAsync(500)
