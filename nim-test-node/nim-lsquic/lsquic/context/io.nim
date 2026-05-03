# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos
import chronos/osdefs
import ./context
import ../[lsquic_ffi, datagram]
import ../helpers/[openarray, sequninit, transportaddr]
import std/[nativesockets, net]

when not defined(windows):
  import posix

when defined(windows):
  import std/winlean

  {.pragma: wsa, stdcall, dynlib: "ws2_32.dll".}

  type WSABUF* = object
    len*: culong
    buf*: ptr char

  proc WSASendTo*(
    s: SocketHandle,
    lpBuffers: ptr WSABUF,
    dwBufferCount: culong,
    lpNumberOfBytesSent: ptr culong,
    dwFlags: culong,
    lpTo: ptr SockAddr,
    iToLen: cint,
    lpOverlapped: pointer,
    lpCompletionRoutine: pointer,
  ): cint {.wsa, importc: "WSASendTo".}

proc prepareDestAddr(
    localSa: ptr SockAddr,
    destSa: ptr SockAddr,
    destStorage: var Sockaddr_storage,
    destAddrLen: var SockLen,
) =
  ## Chronos normalizes IPv4 peers on dual-stack `::` sockets back to IPv4.
  ## When lsquic later asks us to send on that IPv6 socket, sending directly to
  ## an AF_INET destination can fail with EINVAL. Re-map the destination to an
  ## IPv6-mapped address when the local path is IPv6.
  let
    localAddress = localSa.toTransportAddress()
    destAddress = destSa.toTransportAddress()
  if localAddress.family == AddressFamily.IPv6 and
      destAddress.family == AddressFamily.IPv4:
    let mappedDest = destAddress.toIPv6()
    mappedDest.toSAddr(destStorage, destAddrLen)
  else:
    destAddrLen = sockAddrLen(destSa.sa_family.int)
    copyMem(addr destStorage, destSa, destAddrLen)

proc receive*(
    ctx: QuicContext,
    datagram: sink Datagram,
    local: TransportAddress,
    remote: TransportAddress,
) =
  if datagram.len == 0 or not ctx.isRunning():
    return

  var
    localAddress: Sockaddr_storage
    localAddrLen: SockLen
    remoteAddress: Sockaddr_storage
    remoteAddrLen: SockLen

  local.toSAddr(localAddress, localAddrLen)
  remote.toSAddr(remoteAddress, remoteAddrLen)

  discard lsquic_engine_packet_in(
    ctx.engine,
    datagram.data.toPtr,
    datagram.data.len.csize_t,
    cast[ptr SockAddr](addr localAddress),
    cast[ptr SockAddr](addr remoteAddress),
    cast[pointer](ctx),
    datagram.ecn,
  )

  ctx.processWhenReady()

proc sendPacketsOut*(
    ctx: pointer, specs: ptr struct_lsquic_out_spec, nspecs: cuint
): cint {.cdecl.} =
  let quicCtx = cast[QuicContext](ctx)
  var sent = 0
  let specsArr = cast[ptr UncheckedArray[struct_lsquic_out_spec]](specs)
  for i in 0 ..< nspecs.int:
    let curr = specsArr[i]
    var
      destStorage: Sockaddr_storage
      destAddrLen: SockLen
    prepareDestAddr(curr.local_sa, curr.dest_sa, destStorage, destAddrLen)

    when defined(windows):
      let iovArr = cast[ptr UncheckedArray[struct_iovec]](curr.iov)

      var bufs = newSeq[WSABUF](curr.iovlen.int)
      for j in 0 ..< curr.iovlen.int:
        let src = iovArr[j]
        bufs[j].len = culong(src.iov_len)
        bufs[j].buf = cast[ptr char](src.iov_base)

      var bytesSent: culong = 0
      let res = WSASendTo(
        SocketHandle(quicCtx.fd),
        addr bufs[0],
        culong(curr.iovlen),
        addr bytesSent,
        0, # flags
        cast[ptr SockAddr](addr destStorage),
        cint(destAddrLen),
        nil,
        nil, # no overlapped
      )
      if res != 0:
        break
    else:
      let msg =
        when defined(linux) and defined(x86_64):
          Tmsghdr(
            msg_name: cast[pointer](addr destStorage),
            msg_namelen: destAddrLen,
            msg_iov: cast[ptr IOVec](curr.iov),
            msg_iovlen: curr.iovlen.csize_t,
            msg_control: nil,
            msg_controllen: 0,
            msg_flags: 0,
          )
        else:
          Tmsghdr(
            msg_name: cast[pointer](addr destStorage),
            msg_namelen: destAddrLen,
            msg_iov: cast[ptr IOVec](curr.iov),
            msg_iovlen: curr.iovlen.cint,
            msg_control: nil,
            msg_controllen: 0,
            msg_flags: 0,
          )

      let res = sendmsg(SocketHandle(quicCtx.fd), msg.addr, 0)
      if res < 0:
        break

    sent.inc

  sent.cint
