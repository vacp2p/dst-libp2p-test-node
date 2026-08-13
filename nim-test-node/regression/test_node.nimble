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
          "https://github.com/vacp2p/nim-libp2p#a4bcf436c9eaa0f35394bf4af293ecbac7267d5c", # dst/v23-kad-admit-on-cold-start = release/v2.3 + PR 2929 + optimistic admission
          # Both ranges are open upstream, so a new tag would swap the quic stack or the
          # async runtime under a campaign. Held where the v2.2.0 runs had them, leaving
          # nim-libp2p as the only variable between the two versions.
          "lsquic >= 0.8.1 & < 0.8.2",
          "chronos >= 4.2.4 & < 4.3.0"
