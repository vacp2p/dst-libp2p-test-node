# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, chronos/unittest2/asynctests
import lsquic/timeout

suite "timeout":
  asyncTest "earlier deadline replaces later deadline":
    var fired = 0
    let timeout = newTimeout(
      proc() =
        inc fired
    )

    timeout.set(400.milliseconds)
    timeout.set(50.milliseconds)

    await sleepAsync(200.milliseconds)

    check fired == 1

  asyncTest "later deadline does not replace earlier deadline":
    var fired = 0
    let timeout = newTimeout(
      proc() =
        inc fired
    )

    timeout.set(50.milliseconds)
    timeout.set(400.milliseconds)

    await sleepAsync(200.milliseconds)

    check fired == 1

  asyncTest "stop cancels expiry":
    var fired = 0
    let timeout = newTimeout(
      proc() =
        inc fired
    )

    timeout.set(100.milliseconds)
    timeout.stop()

    await sleepAsync(250.milliseconds)

    check fired == 0
