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
          "https://github.com/vacp2p/nim-libp2p#e1ba778e2cafb9d663b0e5a7ab488118a44c9610", # release/v2.3
          # v2.3 wants lsquic >= 0.8.1 with an open upper bound; pin it so a new tag
          # cannot swap the quic stack under a campaign.
          "lsquic >= 0.8.1 & < 0.8.2"