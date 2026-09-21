mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.0",
          "https://github.com/vacp2p/nim-libp2p#e7788a129a91ff20c16ef827669afff6861bfe45", # 2_4-KadLocalCapacity: release/v2.4 head plus the local-capacity liveness deferral
          # Open ranges upstream; held so a new tag cannot swap the stack under a campaign.
          "lsquic >= 0.9.0 & < 0.9.1",
          "chronos >= 4.2.4 & < 4.3.0"
