mode = ScriptMode.Verbose

bin = @["node/main", "bootstrap/main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "nimcrypto 0.6.4",
          "libp2p == 2.0.0"
          # "https://github.com/vacp2p/nim-libp2p#5e9fe7cb5a243cce6b0f729d5b4a8635eedb67ad" # v2.3.0 specific commit