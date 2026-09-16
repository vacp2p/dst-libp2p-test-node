mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "https://github.com/vacp2p/nim-libp2p#7edd055a6d10f5e839342f00af091a7665cd22c3", # release/v2.4 head (v2.4.0 draft release target), stock, no patches
          # Open ranges upstream; held so a new tag cannot swap the stack under a campaign.
          "lsquic >= 0.9.0 & < 0.9.1",
          "chronos >= 4.2.4 & < 4.3.0"
