# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[posix]
import chronicles
import chronos
import ../[lsquic_ffi, errors, stream]
import ../helpers/sequninit

proc onReset*(
    stream: ptr lsquic_stream_t, ctx: ptr lsquic_stream_ctx_t, how: cint
) {.cdecl.} =
  debug "Stream reset", how
  if ctx.isNil:
    debug "stream_ctx is nil onReset"
    return

  let streamCtx = cast[Stream](ctx)

  let sHow =
    case how
    of 0: ResetRead
    of 1: ResetWrite
    of 2: ResetReadWrite
    else: ResetReadWrite

  streamCtx.markResetByPeer(sHow)

  if streamCtx.readResetByPeer():
    streamCtx.failPendingRead(streamCtx.newStreamResetError("stream read"))

  if streamCtx.writeResetByPeer():
    streamCtx.abortPendingWrites(streamCtx.newStreamResetError("stream write"))

proc onClose*(stream: ptr lsquic_stream_t, ctx: ptr lsquic_stream_ctx_t) {.cdecl.} =
  debug "Stream closed"
  if ctx.isNil:
    debug "stream_ctx is nil onClose"
    return

  let streamCtx = cast[Stream](ctx)

  streamCtx.closedByEngine = true

  if not streamCtx.closeWrite:
    streamCtx.abortPendingWrites("stream closed")

  if not streamCtx.readResetByPeer():
    streamCtx.isEof = true

  # Always signal closure so waiters are released, even if we already shut down
  # the write side locally.
  if not streamCtx.closed.isSet():
    streamCtx.closed.fire()

  if streamCtx.readResetByPeer():
    streamCtx.failPendingRead(streamCtx.newStreamResetError("stream read"))
  elif streamCtx.toRead.isSome:
    let doneFut = streamCtx.toRead.unsafeGet().doneFut
    if not doneFut.finished:
      doneFut.fail(newException(StreamError, "stream closed"))
    streamCtx.toRead = Opt.none(ReadTask)

  GC_unref(streamCtx)

proc onRead*(stream: ptr lsquic_stream_t, ctx: ptr lsquic_stream_ctx_t) {.cdecl.} =
  trace "stream read"
  if ctx.isNil:
    debug "stream_ctx is nil onRead"
    return

  let streamCtx = cast[Stream](ctx)

  let task = streamCtx.toRead.valueOr:
    if lsquic_stream_wantread(stream, 0) == -1:
      error "could not set stream wantread", streamId = lsquic_stream_id(stream)
      streamCtx.abort()
    return

  let n = lsquic_stream_read(stream, task.data, task.dataLen.csize_t)

  if n < 0:
    if errno == EWOULDBLOCK:
      # Try later
      return
    elif errno == ECONNRESET:
      if not streamCtx.readResetByPeer():
        streamCtx.markResetByPeer(ResetRead)
      streamCtx.failPendingRead(streamCtx.newStreamResetError("stream read"))
      return
    else:
      error "could not read", streamId = lsquic_stream_id(stream), errno = errno
      streamCtx.abort()
      return

  if n == 0:
    streamCtx.isEof = true

  if lsquic_stream_wantread(stream, 0) == -1:
    error "could not set stream wantread", streamId = lsquic_stream_id(stream)
    streamCtx.abort()

  task.doneFut.complete(int(n))

  streamCtx.toRead = Opt.none(ReadTask)

proc onWrite*(stream: ptr lsquic_stream_t, ctx: ptr lsquic_stream_ctx_t) {.cdecl.} =
  trace "onWrite"

  if ctx.isNil:
    debug "stream_ctx is nil onWrite"
    return

  let streamCtx = cast[Stream](ctx)

  var w = streamCtx.toWrite.valueOr:
    if lsquic_stream_wantwrite(stream, 0) == -1:
      error "could not set stream wantwrite", streamId = lsquic_stream_id(stream)
      streamCtx.abort()
    return

  let dataArr = cast[ptr UncheckedArray[byte]](w.data)
  while not w.doneFut.finished:
    let p = dataArr[w.offset].addr
    let nAvail = (w.dataLen - w.offset).csize_t
    let n: ssize_t = lsquic_stream_write(stream, p, nAvail)
    if n > 0:
      w.offset += n.int
      if w.offset >= w.dataLen:
        if not w.doneFut.finished:
          w.doneFut.complete()
    elif n == 0:
      # Nothing to write, try later
      break
    else:
      if errno == ECONNRESET:
        if not streamCtx.writeResetByPeer():
          streamCtx.markResetByPeer(ResetWrite)
        streamCtx.abortPendingWrites(streamCtx.newStreamResetError("stream write"))
        return
      streamCtx.abortPendingWrites("write failed")
      break

  if lsquic_stream_flush(stream) != 0:
    streamCtx.abort()
    return

  if not w.doneFut.finished:
    streamCtx.toWrite = Opt.some(w)
    return

  streamCtx.toWrite = Opt.none(WriteTask)

  if lsquic_stream_wantwrite(stream, 0) == -1:
    error "could not set stream wantwrite", streamId = lsquic_stream_id(stream)
    streamCtx.abort()
