import std/[json, os, sequtils, sets, strformat]
import chronicles
import stew/byteutils
import libp2p
import libp2p/[crypto/crypto, crypto/curve25519, crypto/secp, multiaddress, stream/connection]
import libp2p/protocols/pubsub/pubsubpeer
import libp2p_mix
import libp2p_mix/[curve25519, mix_node]
import ./env

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

# Picks GossipSubMeshDegree random peers. Used as GossipSub's custom peer
# selector in anonymous mode. directPeers/meshPeers/fanoutPeers are required by
# the callback signature but ignored; selection is uniform over allPeers.
proc mixPeerSelection*(
    allPeers, directPeers, meshPeers, fanoutPeers: HashSet[PubSubPeer]
): HashSet[PubSubPeer] {.gcsafe, raises: [].} =
  var peers: HashSet[PubSubPeer]
  var allPeersSeq = allPeers.toSeq()
  newRng().shuffle(allPeersSeq)
  for p in allPeersSeq:
    peers.incl(p)
    if peers.len >= GossipSubMeshDegree: break
  peers

# Wraps a GossipSub-bound stream through the local MixProtocol.
proc makeMixConnCb*(mixProto: MixProtocol): CustomStreamCreationProc =
  return proc(
      destAddr: Opt[MultiAddress], destPeerId: PeerId, codec: string
  ): Stream {.gcsafe, raises: [].} =
    try:
      let dest = destAddr.valueOr:
        debug "No destination address available"
        return nil
      mixProto.toConnection(MixDestination.init(destPeerId, dest), codec).get()
    except CatchableError as e:
      error "Mix conn creation error", err = e.msg
      nil

{.pop.}
