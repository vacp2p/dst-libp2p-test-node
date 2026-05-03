# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

const
  LSQUIC_GLOBAL_CLIENT* = (1 shl 0)
  LSQUIC_GLOBAL_SERVER* = (1 shl 1)

# Engine modes
const
  LSENG_SERVER* = (1 shl 0)
  LSENG_HTTP* = (1 shl 1)
  LSENG_HTTP_SERVER* = (LSENG_SERVER or LSENG_HTTP)
