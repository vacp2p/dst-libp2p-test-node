import chronos

proc waitShutdownSignal*() {.async.} =
  ## Wait until the process receives SIGINT or SIGTERM.
  let
    sigIntFut = waitSignal(SIGINT)
    sigTermFut = waitSignal(SIGTERM)

  try:
    let completedSignalFut = await one(sigIntFut, sigTermFut)
    await completedSignalFut
  finally:
    if not sigIntFut.finished():
      await noCancel(sigIntFut.cancelAndWait())
    if not sigTermFut.finished():
      await noCancel(sigTermFut.cancelAndWait())
