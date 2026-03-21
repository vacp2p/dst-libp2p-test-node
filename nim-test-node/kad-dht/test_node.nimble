mode = ScriptMode.Verbose

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "nimcrypto 0.6.4",
          "libp2p#a1b9d955e99beece8bec5b72a8ed0af18ce793fe",
          "ggplotnim"
