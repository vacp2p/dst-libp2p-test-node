# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos

type Datagram* = object
  data*: seq[byte]
  ecn*: cint
  peer_ctx*: pointer
  taddr*: TransportAddress

proc len*(datagram: Datagram): int =
  datagram.data.len
