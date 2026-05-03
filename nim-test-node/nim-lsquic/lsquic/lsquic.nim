# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import lsquic_ffi

var initialized: bool

proc initializeLsquic*(client: bool = true, server: bool = true) =
  if initialized:
    return
  initialized = true
  var flags = 0.cint
  if client:
    flags = flags or LSQUIC_GLOBAL_CLIENT
  if server:
    flags = flags or LSQUIC_GLOBAL_SERVER

  if lsquic_global_init(flags) != 0:
    raiseAssert "lsquic initialization failed"

proc cleanupLsquic*() =
  if not initialized:
    return
  lsquic_global_cleanup()
  initialized = false
