mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.6",
          "nimcrypto 0.6.4",
          "https://github.com/vacp2p/nim-libp2p#35ecbb14394454d94c4683420cbf80a249dc5d3e", # 1.16.0
          "ggplotnim"