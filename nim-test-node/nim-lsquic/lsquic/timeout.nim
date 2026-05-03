# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import results
import chronos

type Timeout* = ref object
  timer: Opt[TimerCallback]
  deadline: Opt[Moment]
  onExpiry: proc() {.gcsafe, raises: [].}

const skip = proc() =
  discard

proc newTimeout*(onExpiry: proc() {.gcsafe, raises: [].} = skip): Timeout =
  Timeout(onExpiry: onExpiry)

proc stop*(timeout: Timeout) =
  if timeout.timer.isSome:
    timeout.timer.unsafeGet().clearTimer()
    timeout.timer = Opt.none(TimerCallback)
  timeout.deadline = Opt.none(Moment)

proc set*(timeout: Timeout, moment: Moment) =
  if timeout.timer.isSome and timeout.deadline.isSome and
      timeout.deadline.unsafeGet() <= moment:
    return

  timeout.stop()

  proc onTimeout(_: pointer) {.gcsafe, raises: [].} =
    timeout.stop()
    timeout.onExpiry()

  timeout.deadline = Opt.some(moment)
  timeout.timer = Opt.some(setTimer(moment, onTimeout))

proc set*(timeout: Timeout, duration: Duration) =
  timeout.set(Moment.fromNow(duration))
