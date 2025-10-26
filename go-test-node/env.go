package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/btcsuite/btcd/btcec/v2"
	gcrypto "github.com/ethereum/go-ethereum/crypto"
	logging "github.com/ipfs/go-log/v2"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/multiformats/go-multiaddr"
	ma "github.com/multiformats/go-multiaddr"
)

const (
	myPort = 5000
	//prometheusPort  = 8008
	httpPublishPort = 8645
)

var (
	inShadow = os.Getenv("SHADOWENV") != ""
	chunks   = getEnvInt("FRAGMENTS", 1)
	msgSeen  = make(map[uint64]int)
	log      = logging.Logger("pubsub-test")
)

type PublishRequest struct {
	Topic   string `json:"topic"`
	MsgSize int    `json:"msgSize"`
	Version int    `json:"version"`
}

type PublishResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
}

type PeerInfo struct {
	PeerName string
	Addrs    []ma.Multiaddr
}

func getEnvInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intVal, err := strconv.Atoi(value); err == nil {
			return intVal
		}
	}
	return defaultValue
}

func getHostname() (string, int) {

	hostname, err := os.Hostname()
	if err != nil {
		panic(fmt.Errorf("error getting hostname: %s", err))
	}

	parts := strings.Split(hostname, "-")
	myId, err := strconv.Atoi(parts[1])
	if err != nil {
		panic(fmt.Errorf("error parsing ID from hostname: %s", err))
	}

	return hostname, myId
}

func getEnvVariables() (hostname string, myId int, networkSize int, connectTo int,
	dAnnounce int, muxer string, serviceName string, addr multiaddr.Multiaddr) {

	logging.SetLogLevel("pubsub-test", "info")

	hostname, myId = getHostname()
	networkSize = getEnvInt("PEERS", 100)
	connectTo = getEnvInt("CONNECTTO", 10)
	dAnnounce = getEnvInt("DANNOUNCE", 0) //needed for GossipSub v2.0 only
	muxer = strings.ToLower(os.Getenv("MUXER"))
	serviceName = os.Getenv("SERVICE")
	if serviceName == "" {
		serviceName = "nimp2p-service"
	}

	switch strings.ToLower(muxer) {
	case "yamux":
		addr, _ = multiaddr.NewMultiaddr(fmt.Sprintf("/ip4/0.0.0.0/tcp/%d", myPort))
	case "quic":
		addr, _ = multiaddr.NewMultiaddr(fmt.Sprintf("/ip4/0.0.0.0/udp/%d/quic-v1", myPort))
	default:
		log.Warnw("Invalid or missing MUXER value, defaulting to yamux")
		muxer = "yamux"
		addr, _ = multiaddr.NewMultiaddr(fmt.Sprintf("/ip4/0.0.0.0/tcp/%d", myPort))
	}

	log.Infow("Host info", "hostname", hostname, "peer", myId, "muxer", muxer,
		"inShadow", inShadow, "dAnnounce", dAnnounce, "service", serviceName, "address", addr)

	return
}

func generateKey(hostname string) crypto.PrivKey {
	hash := sha256.Sum256([]byte(hostname))
	p, err := gcrypto.ToECDSA(hash[:])
	if err != nil {
		panic(err)
	}
	privK, _ := btcec.PrivKeyFromBytes(p.D.Bytes())
	key := (*crypto.Secp256k1PrivateKey)(privK)
	return crypto.PrivKey(key)
}
