mode = ScriptMode.Verbose

bin = @["main"]

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.2.4",
          "nimcrypto >= 0.6.0",
          "https://github.com/vacp2p/nim-libp2p#9067f2a5b004fc54a70f53ab02f13f59befa8460" # fix(gossip): make slow peer penalty opt-in by default (#2429)
          #"ggplotnim"