package main

import (
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

	pubsub "github.com/libp2p/go-libp2p-pubsub"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var _ pubsub.RawTracer = (*GossipSubTracer)(nil)

func startMetricsServer() error {
	addr := fmt.Sprintf("0.0.0.0:%d", prometheusPort)
	log.Infow("Starting metrics HTTP server", "address", addr)

	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("failed to bind metrics server: %w", err)
	}

	http.Handle("/metrics", promhttp.Handler())
	go http.Serve(listener, nil)

	log.Infow("Metrics HTTP server started", "port", prometheusPort)
	return nil
}

var (
	libp2pNetworkBytes = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_network_bytes_total",
			Help: "total traffic",
		},
		[]string{"direction"},
	)

	libp2pOpenStreams = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "libp2p_open_streams",
			Help: "open stream instances",
		},
		[]string{"type", "dir"},
	)

	libp2pPeers = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "libp2p_peers",
			Help: "total connected peers",
		},
	)

	libp2pPubsubPeers = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "libp2p_pubsub_peers",
			Help: "pubsub peer instances",
		},
	)

	libp2pPubsubTopics = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "libp2p_pubsub_topics",
			Help: "pubsub subscribed topics",
		},
	)

	libp2pPubsubMessagesPublished = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_messages_published_total",
			Help: "published messages",
		},
		[]string{"topic"},
	)

	libp2pPubsubBroadcastMessages = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_broadcast_messages_total",
			Help: "pubsub broadcast messages",
		},
		[]string{"topic"},
	)

	libp2pPubsubReceivedMessages = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_received_messages_total",
			Help: "pubsub received messages",
		},
		[]string{"topic"},
	)

	libp2pPubsubBroadcastSubscriptions = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_broadcast_subscriptions_total",
			Help: "pubsub broadcast subscriptions",
		},
		[]string{"topic"},
	)

	libp2pPubsubBroadcastUnsubscriptions = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_broadcast_unsubscriptions_total",
			Help: "pubsub broadcast unsubscriptions",
		},
		[]string{"topic"},
	)

	libp2pPubsubReceivedSubscriptions = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_received_subscriptions_total",
			Help: "pubsub received subscriptions",
		},
		[]string{"topic"},
	)

	libp2pPubsubReceivedUnsubscriptions = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_received_unsubscriptions_total",
			Help: "pubsub received unsubscriptions",
		},
		[]string{"topic"},
	)

	libp2pPubsubBroadcastIhave = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_broadcast_ihave_total",
			Help: "pubsub broadcast ihave",
		},
		[]string{"topic"},
	)

	libp2pPubsubReceivedIhave = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_received_ihave_total",
			Help: "pubsub received ihave",
		},
		[]string{"topic"},
	)

	libp2pPubsubBroadcastIwant = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_broadcast_iwant_total",
			Help: "pubsub broadcast iwant",
		},
	)

	libp2pPubsubReceivedIwant = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_received_iwant_total",
			Help: "pubsub received iwant",
		},
	)

	libp2pPubsubBroadcastGraft = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_broadcast_graft_total",
			Help: "pubsub broadcast graft",
		},
		[]string{"topic"},
	)

	libp2pPubsubReceivedGraft = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_received_graft_total",
			Help: "pubsub received graft",
		},
		[]string{"topic"},
	)

	libp2pPubsubBroadcastPrune = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_broadcast_prune_total",
			Help: "pubsub broadcast prune",
		},
		[]string{"topic"},
	)

	libp2pPubsubReceivedPrune = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_received_prune_total",
			Help: "pubsub received prune",
		},
		[]string{"topic"},
	)

	libp2pPubsubBroadcastIdontwant = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_broadcast_idontwant_total",
			Help: "pubsub broadcast idontwant",
		},
	)

	libp2pPubsubReceivedIdontwant = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_received_idontwant_total",
			Help: "pubsub received idontwant",
		},
	)

	libp2pGossipsubDuplicate = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_gossipsub_duplicate_total",
			Help: "number of duplicates received",
		},
	)

	libp2pGossipsubReceived = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_gossipsub_received_total",
			Help: "number of messages received (deduplicated)",
		},
	)

	libp2pGossipsubPeersPerTopicMesh = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "libp2p_gossipsub_peers_per_topic_mesh",
			Help: "gossipsub peers per topic in mesh",
		},
		[]string{"topic"},
	)

	libp2pGossipsubPeersPerTopicGossipsub = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "libp2p_gossipsub_peers_per_topic_gossipsub",
			Help: "gossipsub peers per topic in gossipsub",
		},
		[]string{"topic"},
	)

	libp2pGossipsubLowPeersTopics = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "libp2p_gossipsub_low_peers_topics",
			Help: "number of topics in mesh with at least one but below dlow peers",
		},
	)

	libp2pGossipsubHealthyPeersTopics = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "libp2p_gossipsub_healthy_peers_topics",
			Help: "number of topics in mesh with at least dlow peers",
		},
	)

	libp2pGossipsubNoPeersTopics = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "libp2p_gossipsub_no_peers_topics",
			Help: "number of topics in mesh with no peers",
		},
	)

	libp2pPubsubValidationSuccess = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_validation_success_total",
			Help: "pubsub successfully validated messages",
		},
	)

	libp2pPubsubValidationFailure = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_validation_failure_total",
			Help: "pubsub failed validated messages",
		},
	)

	libp2pPubsubRejectReason = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_reject_reason_total",
			Help: "pubsub rejected messages by reason",
		},
		[]string{"reason"},
	)

	libp2pPubsubRPCDrop = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "libp2p_pubsub_rpc_drop_total",
			Help: "number of RPCs dropped",
		},
	)
)

type GossipSubTracer struct {
	meshPeerCount map[string]int
	mu            sync.RWMutex
	dLow          int
}

func NewGossipSubTracer(dLow int) *GossipSubTracer {
	return &GossipSubTracer{
		meshPeerCount: make(map[string]int),
		dLow:          dLow,
	}
}

func (t *GossipSubTracer) AddPeer(p peer.ID, proto protocol.ID) {
	libp2pPubsubPeers.Inc()
}

func (t *GossipSubTracer) RemovePeer(p peer.ID) {
	libp2pPubsubPeers.Dec()
}

func (t *GossipSubTracer) Join(topic string) {
	t.mu.Lock()
	if _, exists := t.meshPeerCount[topic]; !exists {
		t.meshPeerCount[topic] = 0
		t.updateTopicHealthMetrics()
	}
	t.mu.Unlock()
}

func (t *GossipSubTracer) Leave(topic string) {
	t.mu.Lock()
	if _, exists := t.meshPeerCount[topic]; exists {
		delete(t.meshPeerCount, topic)
		t.updateTopicHealthMetrics()
	}
	t.mu.Unlock()
}

func (t *GossipSubTracer) Graft(p peer.ID, topic string) {
	t.mu.Lock()
	t.meshPeerCount[topic]++
	libp2pGossipsubPeersPerTopicMesh.WithLabelValues(topic).Set(float64(t.meshPeerCount[topic]))
	t.updateTopicHealthMetrics()
	t.mu.Unlock()
}

func (t *GossipSubTracer) Prune(p peer.ID, topic string) {
	t.mu.Lock()
	t.meshPeerCount[topic]--
	if t.meshPeerCount[topic] < 0 {
		t.meshPeerCount[topic] = 0
	}
	libp2pGossipsubPeersPerTopicMesh.WithLabelValues(topic).Set(float64(t.meshPeerCount[topic]))
	t.updateTopicHealthMetrics()
	t.mu.Unlock()
}

// Not thread safe
func (t *GossipSubTracer) updateTopicHealthMetrics() {
	var noPeers, lowPeers, healthy int
	for _, count := range t.meshPeerCount {
		if count == 0 {
			noPeers++
		} else if count < t.dLow {
			lowPeers++
		} else {
			healthy++
		}
	}
	libp2pGossipsubNoPeersTopics.Set(float64(noPeers))
	libp2pGossipsubLowPeersTopics.Set(float64(lowPeers))
	libp2pGossipsubHealthyPeersTopics.Set(float64(healthy))
}

func (t *GossipSubTracer) ValidateMessage(msg *pubsub.Message) {}

func (t *GossipSubTracer) DeliverMessage(msg *pubsub.Message) {
	libp2pGossipsubReceived.Inc()
	libp2pPubsubValidationSuccess.Inc()
}

func (t *GossipSubTracer) RejectMessage(msg *pubsub.Message, reason string) {
	libp2pPubsubValidationFailure.Inc()
	libp2pPubsubRejectReason.WithLabelValues(reason).Inc()
}

func (t *GossipSubTracer) DuplicateMessage(msg *pubsub.Message) {
	libp2pGossipsubDuplicate.Inc()
}

func (t *GossipSubTracer) ThrottlePeer(p peer.ID) {}

func (t *GossipSubTracer) RecvRPC(rpc *pubsub.RPC) {
	size := rpc.Size()
	libp2pNetworkBytes.WithLabelValues("in").Add(float64(size))

	for _, sub := range rpc.GetSubscriptions() {
		topic := sub.GetTopicid()
		if sub.GetSubscribe() {
			libp2pPubsubReceivedSubscriptions.WithLabelValues(topic).Inc()
		} else {
			libp2pPubsubReceivedUnsubscriptions.WithLabelValues(topic).Inc()
		}
	}

	if rpc.Control != nil {
		for _, ihave := range rpc.Control.GetIhave() {
			topic := ihave.GetTopicID()
			libp2pPubsubReceivedIhave.WithLabelValues(topic).Inc()
		}

		libp2pPubsubReceivedIwant.Add(float64(len(rpc.Control.GetIwant())))

		for _, graft := range rpc.Control.GetGraft() {
			topic := graft.GetTopicID()
			libp2pPubsubReceivedGraft.WithLabelValues(topic).Inc()
		}

		for _, prune := range rpc.Control.GetPrune() {
			topic := prune.GetTopicID()
			libp2pPubsubReceivedPrune.WithLabelValues(topic).Inc()
		}

		libp2pPubsubReceivedIdontwant.Add(float64(len(rpc.Control.GetIdontwant())))
	}

	for _, msg := range rpc.GetPublish() {
		topic := msg.GetTopic()
		libp2pPubsubReceivedMessages.WithLabelValues(topic).Inc()
	}
}

func (t *GossipSubTracer) SendRPC(rpc *pubsub.RPC, p peer.ID) {
	size := rpc.Size()
	libp2pNetworkBytes.WithLabelValues("out").Add(float64(size))

	for _, sub := range rpc.GetSubscriptions() {
		topic := sub.GetTopicid()
		if sub.GetSubscribe() {
			libp2pPubsubBroadcastSubscriptions.WithLabelValues(topic).Inc()
		} else {
			libp2pPubsubBroadcastUnsubscriptions.WithLabelValues(topic).Inc()
		}
	}

	if rpc.Control != nil {
		for _, ihave := range rpc.Control.GetIhave() {
			topic := ihave.GetTopicID()
			libp2pPubsubBroadcastIhave.WithLabelValues(topic).Inc()
		}

		libp2pPubsubBroadcastIwant.Add(float64(len(rpc.Control.GetIwant())))

		for _, graft := range rpc.Control.GetGraft() {
			topic := graft.GetTopicID()
			libp2pPubsubBroadcastGraft.WithLabelValues(topic).Inc()
		}

		for _, prune := range rpc.Control.GetPrune() {
			topic := prune.GetTopicID()
			libp2pPubsubBroadcastPrune.WithLabelValues(topic).Inc()
		}

		libp2pPubsubBroadcastIdontwant.Add(float64(len(rpc.Control.GetIdontwant())))
	}

	for _, msg := range rpc.GetPublish() {
		topic := msg.GetTopic()
		libp2pPubsubBroadcastMessages.WithLabelValues(topic).Inc()
	}
}

func (t *GossipSubTracer) DropRPC(rpc *pubsub.RPC, p peer.ID) {
	libp2pPubsubRPCDrop.Inc()
}

func (t *GossipSubTracer) UndeliverableMessage(msg *pubsub.Message) {}

// Helper to record published messages
func RecordMessagePublished(topic string) {
	libp2pPubsubMessagesPublished.WithLabelValues(topic).Inc()
}

// Initialize metrics for topics
func InitPubsubMetrics(topics []string) {
	for _, topic := range topics {
		libp2pPubsubMessagesPublished.WithLabelValues(topic)
		libp2pPubsubReceivedMessages.WithLabelValues(topic)
		libp2pPubsubBroadcastMessages.WithLabelValues(topic)
		libp2pPubsubBroadcastSubscriptions.WithLabelValues(topic)
		libp2pPubsubBroadcastUnsubscriptions.WithLabelValues(topic)
		libp2pPubsubReceivedSubscriptions.WithLabelValues(topic)
		libp2pPubsubReceivedUnsubscriptions.WithLabelValues(topic)
		libp2pPubsubBroadcastIhave.WithLabelValues(topic)
		libp2pPubsubReceivedIhave.WithLabelValues(topic)
		libp2pPubsubBroadcastGraft.WithLabelValues(topic)
		libp2pPubsubReceivedGraft.WithLabelValues(topic)
		libp2pPubsubBroadcastPrune.WithLabelValues(topic)
		libp2pPubsubReceivedPrune.WithLabelValues(topic)
		libp2pGossipsubPeersPerTopicMesh.WithLabelValues(topic).Set(0)
		libp2pGossipsubPeersPerTopicGossipsub.WithLabelValues(topic).Set(0)
	}

	libp2pNetworkBytes.WithLabelValues("in")
	libp2pNetworkBytes.WithLabelValues("out")
}

// periodically Update metrics with no callbacks
func UpdateHostMetrics(h host.Host, ps *pubsub.PubSub, topics []string, muxer string) {
	var inboundStreams, outboundStreams int
	var inboundConns, outboundConns int

	for _, conn := range h.Network().Conns() {
		// SecureConns
		stat := conn.Stat()
		if stat.Direction == network.DirInbound {
			inboundConns++
		} else {
			outboundConns++
		}

		// multiplexed streams
		for _, stream := range conn.GetStreams() {
			streamStat := stream.Stat()
			if streamStat.Direction == network.DirInbound {
				inboundStreams++
			} else {
				outboundStreams++
			}
		}
	}

	streamType := "YamuxStream"
	if muxer == "quic" {
		streamType = "QUICStream"
	}

	libp2pOpenStreams.WithLabelValues(streamType, "In").Set(float64(inboundStreams))
	libp2pOpenStreams.WithLabelValues(streamType, "Out").Set(float64(outboundStreams))
	libp2pOpenStreams.WithLabelValues("SecureConn", "In").Set(float64(inboundConns))
	libp2pOpenStreams.WithLabelValues("SecureConn", "Out").Set(float64(outboundConns))

	libp2pPeers.Set(float64(len(h.Network().Peers())))

	if ps != nil {
		for _, topic := range topics {
			peers := ps.ListPeers(topic)
			libp2pGossipsubPeersPerTopicGossipsub.WithLabelValues(topic).Set(float64(len(peers)))
		}
		libp2pPubsubTopics.Set(float64(len(topics)))
	}
}

func StartHostMetricsUpdater(h host.Host, ps *pubsub.PubSub, topics []string, muxer string) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		UpdateHostMetrics(h, ps, topics, muxer)
	}
}
