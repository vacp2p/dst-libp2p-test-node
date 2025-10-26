package main

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/libp2p/go-libp2p"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	pb "github.com/libp2p/go-libp2p-pubsub/pb"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/muxer/yamux"
	quic "github.com/libp2p/go-libp2p/p2p/transport/quic"
	ma "github.com/multiformats/go-multiaddr"
)

func msgIdProvider(pmsg *pb.Message) string {
	hash := sha256.Sum256(pmsg.Data)
	return string(hash[:])
}

func messageHandler(topic string, data []byte) {

	sentUint := binary.LittleEndian.Uint64(data[:8])

	// Warm-up
	if sentUint < 1000000 {
		return
	}

	// Accumulate all fragments
	msgSeen[sentUint]++
	if msgSeen[sentUint] < chunks {
		return
	}

	sentNanos := int64(sentUint)
	sentTime := time.Unix(0, sentNanos)
	diff := time.Since(sentTime)
	fmt.Printf("%d milliseconds: %d\n", sentUint, diff.Milliseconds())
}

func readLoop(sub *pubsub.Subscription, ctx context.Context, topic string) {
	for {
		msg, err := sub.Next(ctx)
		if err != nil {
			log.Errorw("Error reading message", "error", err)
			continue
		}
		messageHandler(topic, msg.Data)
	}
}

func publishNewMessage(topic *pubsub.Topic, msgSize int, ctx context.Context) (time.Time, error) {
	now := time.Now()
	nowNanos := now.UnixNano()

	//create payload with timestamp, so the receiver can discover elapsed time
	nowBytes := make([]byte, 8)
	binary.LittleEndian.PutUint64(nowBytes, uint64(nowNanos))
	payload := append(nowBytes, make([]byte, msgSize/chunks)...)

	//To support message fragmentation, we add fragment no. Each fragment (chunk) differs by one byte
	for chunk := 0; chunk < chunks; chunk++ {
		payload[10] = byte(chunk)
		if err := topic.Publish(ctx, payload); err != nil {
			return now, err
		}
	}
	return now, nil
}

// http endpoint for detached controller
func startHTTPServer(ctx context.Context, ps *pubsub.PubSub, topics map[string]*pubsub.Topic) {
	httpMux := http.NewServeMux()
	// Look for incoming requests from publish controller
	httpMux.HandleFunc("/publish", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method Not Supported", http.StatusMethodNotAllowed)
			return
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		var req PublishRequest
		if err := json.Unmarshal(body, &req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		topic, exists := topics[req.Topic]
		if !exists {
			http.Error(w, "Topic not joined", http.StatusInternalServerError)
			return
		}

		log.Infow("controller message", "command", r.URL.Path, "topic", req.Topic, "size", req.MsgSize, "version", req.Version)

		// Publish message
		publishTime, err := publishNewMessage(topic, req.MsgSize, ctx)

		var resp PublishResponse
		if err != nil {
			resp = PublishResponse{
				Status:  "error",
				Message: fmt.Sprintf("Failed to publish %v", err),
			}
			w.WriteHeader(http.StatusInternalServerError)
		} else {
			resp = PublishResponse{
				Status:  "success",
				Message: fmt.Sprintf("Message published at time %v", publishTime),
			}
			w.WriteHeader(http.StatusOK)
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	})

	addr := fmt.Sprintf("0.0.0.0:%d", httpPublishPort)
	log.Infow("Starting HTTP server", "address", addr)

	server := &http.Server{
		Addr:    addr,
		Handler: httpMux,
	}

	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Errorw("Failed to create HTTP server: ", "error", err)
		}
	}()

	log.Infow("HTTP server started", "httpPort", httpPublishPort)
}

func configureGossipsubParams() pubsub.GossipSubParams {
	gsParams := pubsub.DefaultGossipSubParams()

	gsParams.D = 6
	gsParams.Dlo = 4
	gsParams.Dhi = 8
	gsParams.Dscore = 6
	gsParams.Dout = 2
	gsParams.Dlazy = 6
	gsParams.HeartbeatInterval = time.Duration(1000) * time.Millisecond
	gsParams.PruneBackoff = time.Minute
	gsParams.GossipFactor = 0.25
	gsParams.IDontWantMessageThreshold = 1000

	//GossipSubv2.0 specific
	/*
		gsParams.HistoryLength = 6
		gsParams.HistoryGossip = 3
		gsParams.Dannounce = 7
	*/

	return gsParams
}

func subscribeGossipsubTopic(ps *pubsub.PubSub, topicName string, topics map[string]*pubsub.Topic) (*pubsub.Subscription, error) {

	topic, err := ps.Join(topicName)
	if err != nil {
		return nil, fmt.Errorf("error joining topic %s: %v", topicName, err)
	}
	topics[topicName] = topic

	// Set topic score parameters
	topicScoreParams := &pubsub.TopicScoreParams{
		TopicWeight:                  1,
		FirstMessageDeliveriesWeight: 1,
		FirstMessageDeliveriesCap:    30,
		FirstMessageDeliveriesDecay:  0.9,
		// Allow partial parameter setting
		SkipAtomicValidation: true,
	}

	if err := topic.SetScoreParams(topicScoreParams); err != nil {
		log.Warnw("failed to set topic score params", "topic", topicName, "error", err)
	}

	// Subscribe to the topic
	sub, err := topic.Subscribe()
	if err != nil {
		return nil, fmt.Errorf("error subscribing to topic %s: %v", topicName, err)
	}

	log.Infow("Subscribed to topic", "topic", topicName)
	return sub, nil
}

func resolveAddress(muxer string, tAddress string) ([]*PeerInfo, error) {
	maxRetries := 5
	var ips []net.IP
	var lookupErr error
	for attempt := 1; attempt <= maxRetries; attempt++ {
		ips, lookupErr = net.LookupIP(tAddress)
		if lookupErr != nil {
			log.Warnw("Failed to resolve address", "address", tAddress, "error", lookupErr)
			if inShadow || attempt == maxRetries {
				return nil, lookupErr
			}
			//Reattempt service after 15 seconds
			time.Sleep(15 * time.Second)
		} else {
			break
		}
	}

	var peerInfos []*PeerInfo
	for _, ip := range ips {
		var maddr ma.Multiaddr
		var maddrErr error

		ipStr := ip.String()
		switch muxer {
		case "quic":
			maddr, maddrErr = ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/udp/%d/quic-v1", ipStr, myPort))
		default:
			maddr, maddrErr = ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/%d", ipStr, myPort))
		}

		if maddrErr != nil {
			log.Errorw("Failed to create multiaddr", "error", maddrErr)
			continue
		}

		var peerName string
		if inShadow {
			peerName = tAddress
		} else {
			//Do reverse lookup for hostName in k8s
			hostnames, err := net.LookupAddr(ipStr)
			if err != nil || len(hostnames) == 0 {
				log.Warnw("Failed to find peerName", "ip", ipStr, "error", err)
				continue
			}
			peerName = strings.Split(hostnames[0], ".")[0]
		}

		peerInfo := &PeerInfo{
			PeerName: peerName,
			Addrs:    []ma.Multiaddr{maddr},
		}
		peerInfos = append(peerInfos, peerInfo)
		log.Infow("Address resolved", "peerName", peerName, "Multiaddress", maddr)
		if inShadow {
			break
		}
	}

	if len(peerInfos) == 0 {
		return nil, fmt.Errorf("no valid addresses resolved")
	}

	return peerInfos, nil
}

func connectToPeers(ctx context.Context, h host.Host, myID, networkSize, connectTo int, muxer, service string) {

	//var addrs []ma.Multiaddr
	var tAddresses []string
	source := rand.NewSource(int64(myID))
	rnd := rand.New(source)

	if inShadow {
		numbers := make([]int, 0, networkSize-1)
		for i := 0; i < networkSize; i++ {
			if i != myID {
				numbers = append(numbers, i)
			}
		}

		rnd.Shuffle(len(numbers), func(i, j int) {
			numbers[i], numbers[j] = numbers[j], numbers[i]
		})

		//for shadow, collect enough random peers to make target connections
		for i := 0; i < min(connectTo*2, len(numbers)); i++ {
			tAddresses = append(tAddresses, fmt.Sprintf("pod-%d", numbers[i]))
		}
	} else {
		//Use name service for k8s
		tAddresses = append(tAddresses, service)
	}

	var peerInfos []*PeerInfo
	for _, tAddress := range tAddresses {
		resolvedPeers, err := resolveAddress(muxer, tAddress)
		if err != nil {
			log.Warnw("Failed to resolve address", "tAddress", tAddress, "error", err)
			continue
		}
		peerInfos = append(peerInfos, resolvedPeers...)
	}

	connected := 0
	rnd.Shuffle(len(peerInfos), func(i, j int) {
		peerInfos[i], peerInfos[j] = peerInfos[j], peerInfos[i]
	})
	for _, peerInfo := range peerInfos {
		if connected > connectTo {
			break
		}

		// Generate peer ID from hostname
		nodeID, err := peer.IDFromPrivateKey(generateKey(peerInfo.PeerName))
		if err != nil {
			log.Errorw("Error generating nodeID", "peerName", peerInfo.PeerName, "error", err)
			continue
		}

		info := peer.AddrInfo{
			ID:    nodeID,
			Addrs: peerInfo.Addrs,
		}

		log.Infow("Connecting to", "peerId", nodeID, "addresses", peerInfo.Addrs)

		connCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		if err := h.Connect(connCtx, info); err != nil {
			log.Warnw("Failed to connect", "peerId", nodeID, "error", err)
			cancel()
			time.Sleep(2 * time.Second)
		} else {
			connected++
			log.Infow("Connected!: Current connections", "connected", connected, "target", connectTo)
			cancel()
		}
	}
}

func main() {
	ctx := context.Background()
	hostname, myId, networkSize, connectTo, _, muxer, service, address := getEnvVariables()

	pk := generateKey(hostname)
	var opts []libp2p.Option
	opts = append(opts, libp2p.Identity(pk))
	opts = append(opts, libp2p.ListenAddrs(address))

	switch strings.ToLower(muxer) {
	case "quic":
		opts = append(opts, libp2p.Transport(quic.NewTransport))
	default:
		opts = append(opts, libp2p.Muxer("/yamux/1.0.0", yamux.DefaultTransport))
	}

	host, err := libp2p.New(opts...)
	if err != nil {
		panic(fmt.Errorf("error creating host: %s", err))
	}

	// Create GossipSub
	gsParams := configureGossipsubParams()
	ps, err := pubsub.NewGossipSub(ctx, host,
		pubsub.WithGossipSubParams(gsParams),
		pubsub.WithMessageIdFn(msgIdProvider),
		pubsub.WithFloodPublish(true),
		//pubsub.WithPeerOutboundQueueSize(600),
		//pubsub.WithMaxMessageSize(10*1<<20),
		//pubsub.WithValidateQueueSize(600),
		pubsub.WithMessageSignaturePolicy(pubsub.StrictNoSign),
	)
	if err != nil {
		panic(fmt.Errorf("error creating pubsub: %s", err))
	}

	// Join and store topics
	topics := make(map[string]*pubsub.Topic)
	sub, err := subscribeGossipsubTopic(ps, "test", topics)
	if err != nil {
		panic(fmt.Errorf("error joining topic: %v", err))
	}

	log.Infow("Listening on", "address", host.Addrs())
	log.Infow("Peer details", "peer", myId, "peerId", host.ID())

	// Start message reader
	go readLoop(sub, ctx, "test")

	// Wait for node building
	log.Infow("Waiting for node initialization...")
	time.Sleep(5 * time.Second)

	// Connect to peers
	connectToPeers(ctx, host, myId, networkSize, connectTo, muxer, service)

	// Wait for mesh building
	time.Sleep(5 * time.Second)

	peers := ps.ListPeers("test")
	fmt.Printf("Mesh size: %d\n", len(peers))

	// Start HTTP server for publish controller
	fmt.Println("Starting listening endpoint for publish controller")
	startHTTPServer(ctx, ps, topics)

	time.Sleep(48 * time.Hour)
}
