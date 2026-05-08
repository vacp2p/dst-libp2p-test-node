mode = ScriptMode.Verbose

packageName   = "service_discovery_test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for libp2p service discovery"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "nimcrypto 0.6.4",
          "libp2p"
