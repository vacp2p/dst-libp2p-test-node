mode = ScriptMode.Verbose

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for libp2p service discovery"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.4",
          "nimcrypto 0.6.4",
          "https://github.com/vacp2p/nim-libp2p#f0c97fcf410cc35c082aebb15f6568eae206da3d" # 2.2.0 tag
