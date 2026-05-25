mode = ScriptMode.Verbose

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for libp2p service discovery"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "nimcrypto 0.6.4",
          "libp2p#d4cd68b91b82f34a0ede3766ab1ca8119d5015f8"
