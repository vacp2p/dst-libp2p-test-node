# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos
import chronos/osdefs
import ../lsquic_ffi

# up until nim 2.2.6, AF_INET6 const had wrong value. 
# that's why this const is defiend here to have backwards compatability with older versions of nim.
# commit fix: https://github.com/nim-lang/Nim/commit/248850a0ce869c15fea16a35e248850d2df47c8d
const fixed_AF_INET6 =
  when defined(macosx):
    30
  elif defined(windows):
    23
  else:
    10

proc sockAddrLen*(family: int): SockLen {.inline.} =
  case family
  of AF_INET.int:
    sizeof(Sockaddr_in).uint32
  of fixed_AF_INET6.int: # use fixed const
    sizeof(Sockaddr_in6).uint32
  else:
    raiseAssert "invalid socket address family"

proc toTransportAddress*(sock: ptr SockAddr): TransportAddress =
  var destAddress: Sockaddr_storage
  let destAddrLen: SockLen = sockAddrLen(sock.sa_family.int)
  copyMem(addr destAddress, sock, destAddrLen)
  var taddr: TransportAddress
  fromSAddr(addr destAddress, destAddrLen, taddr)
  taddr
