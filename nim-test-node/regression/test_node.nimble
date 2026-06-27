mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "nimcrypto 0.6.4",
          "https://github.com/vacp2p/nim-libp2p#6867e6e3ffc0f3c4ff19585f352b3b6419480312", # release/v2.1.0 + #2605 + #2678 (cancelStreamHandlers nil-deref fix)
          "ggplotnim"