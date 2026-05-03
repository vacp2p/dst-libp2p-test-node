# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos
import ./connection

type ConnectionManager* = ref object of RootObj
  connections: seq[Connection]
  closed*: Future[void]

proc new*(T: typedesc[ConnectionManager]): T =
  let ret = ConnectionManager()
  ret.closed = newFuture[void]()
  ret

proc stop*(connman: ConnectionManager) {.async: (raises: [CancelledError]).} =
  if connman.closed.finished:
    return

  connman.closed.complete()
  let active = connman.connections
  connman.connections = @[]
  for conn in active:
    conn.abort()

proc removeConnection(connman: ConnectionManager, conn: Connection) {.raises: [].} =
  for i in 0 ..< connman.connections.len:
    if connman.connections[i] == conn:
      let last = connman.connections.high
      connman.connections[i] = connman.connections[last]
      connman.connections.setLen(last)
      break

proc addConnection*(connman: ConnectionManager, conn: Connection) =
  connman.connections.add(conn)
  let fut = conn.closedFuture()
  if fut.finished:
    connman.removeConnection(conn)
  else:
    fut.addCallback(
      proc(_: pointer) {.gcsafe, raises: [].} =
        connman.removeConnection(conn)
    )
