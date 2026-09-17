mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "https://github.com/vacp2p/nim-libp2p#cc170a913717869ba52513c650ca0257129cdc4a", # 2_4-KadBypassProbe: release/v2.4 head plus the admission-probe bypass
          # Open ranges upstream; held so a new tag cannot swap the stack under a campaign.
          "lsquic >= 0.9.0 & < 0.9.1",
          "chronos >= 4.2.4 & < 4.3.0"
