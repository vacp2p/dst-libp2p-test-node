# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import unittest2
import lsquic

suite "runtime":
  test "initialize and cleanup are repeatable":
    cleanupLsquic()

    for _ in 0 ..< 3:
      initializeLsquic(true, true)
      initializeLsquic(true, true)
      cleanupLsquic()
      cleanupLsquic()

    initializeLsquic(true, true)
    cleanupLsquic()
