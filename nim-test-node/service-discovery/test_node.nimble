mode = ScriptMode.Verbose

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for libp2p service discovery"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.4",
          "nimcrypto 0.6.4",
          "https://github.com/vacp2p/nim-libp2p#c44b81ddb54c4902c8d97d5b8113853bc3f43f2f" # 2.1.0 specific
