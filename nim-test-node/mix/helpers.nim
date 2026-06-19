import std/[json, os, strformat]
import stew/byteutils
import libp2p
import libp2p/[crypto/crypto, crypto/curve25519, crypto/secp, multiaddress]
import libp2p_mix
import libp2p_mix/[curve25519, mix_node]

{.push raises: [].}

# For peers to exchange MixPubInfo via shared filesystem.
proc toMixPubInfoJson*(info: MixPubInfo): string =
  $(%* {
    "peerId": $info.peerId,
    "multiAddr": $info.multiAddr,
    "mixPubKey": byteutils.toHex(info.mixPubKey.getBytes()),
    "libp2pPubKey": byteutils.toHex(info.libp2pPubKey.getBytes()),
  })

proc mixPubInfoFromJson*(s: string): Result[MixPubInfo, string] =
  try:
    let j = parseJson(s)
    let peerId = PeerId.init(j["peerId"].getStr()).valueOr:
      return err("invalid peerId: " & $error)
    let multiAddr = MultiAddress.init(j["multiAddr"].getStr()).valueOr:
      return err("invalid multiAddr: " & $error)
    let mixPubKey = bytesToFieldElement(hexToSeqByte(j["mixPubKey"].getStr())).valueOr:
      return err("invalid mixPubKey: " & error)
    let libp2pPubKey = SkPublicKey.init(hexToSeqByte(j["libp2pPubKey"].getStr())).valueOr:
      return err("invalid libp2pPubKey: " & $error)
    ok(MixPubInfo.init(peerId, multiAddr, mixPubKey, libp2pPubKey))
  except CatchableError as e:
    err("parse failed: " & e.msg)

proc writeMixPubInfoFile*(info: MixPubInfo, myId: int, dir: string): Result[void, string] =
  try:
    createDir(dir)
    writeFile(dir / fmt"pubInfo_{myId}.json", toMixPubInfoJson(info))
    ok()
  except CatchableError as e:
    err("write failed: " & e.msg)

proc readMixPubInfoFile*(id: int, dir: string): Result[MixPubInfo, string] =
  let path = dir / fmt"pubInfo_{id}.json"
  let content =
    try: readFile(path)
    except CatchableError as e: return err("read failed: " & e.msg)
  mixPubInfoFromJson(content)

{.pop.}
