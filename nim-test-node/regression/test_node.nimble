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
          # nim-libp2p wants boringssl >= 0.0.11. Nimble walks the tags, and switching the
          # boringssl submodule between tags fails in the build container, which makes it
          # drop every tag in range. Pinning the commit skips the tag walk.
          "https://github.com/vacp2p/nim-boringssl#fbf9c2762241be3f004d45b9a32b7bfd6ea136a8", # v0.0.13
          "chronos >= 4.2.4 & < 4.3.0"
