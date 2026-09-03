mode = ScriptMode.Verbose

bin = @["node/main", "bootstrap/main"]
namedBin = {"node/main": "regression-node", "bootstrap/main": "regression-bootstrap"}.toTable()

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "nimcrypto 0.6.4",
          "libp2p == 2.3.1",
          "lsquic == 0.8.1"