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
          "https://github.com/vacp2p/nim-libp2p#7edd055a6d10f5e839342f00af091a7665cd22c3", # release/v2.4 head (v2.4.0 draft release target), stock, no patches
          # Both ranges are open upstream, so a new tag would swap the quic stack or the
          # async runtime under a campaign. lsquic held at the release's own bump (0.9.0),
          # chronos where the v2.2.0 and v2.3.0 runs had it.
          "lsquic >= 0.9.0 & < 0.9.1",
          "chronos >= 4.2.4 & < 4.3.0"
