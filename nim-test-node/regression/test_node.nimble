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
          "https://github.com/vacp2p/nim-libp2p#b4af72b84c3cea36cf6225c62fca14237d323827", # 2.1.0
          "ggplotnim"