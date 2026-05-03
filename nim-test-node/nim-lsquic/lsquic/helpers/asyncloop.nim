# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos

proc asyncLoop*(
    repeat: proc(): Future[void].Raising([CancelledError]) {.gcsafe, raises: [].}
): Future[void] {.async: (raises: [CancelledError]).} =
  ## Repeatedly calls the async proc `repeat` until cancelled.
  while true:
    try:
      await repeat()
    except CancelledError as e:
      raise e
