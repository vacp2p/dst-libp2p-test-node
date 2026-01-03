use prometheus_client::{
    encoding::EncodeLabelSet,
    metrics::{counter::Counter, family::Family, gauge::Gauge},
    registry::Registry,
};

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
pub struct TopicLabels {
    pub topic: String,
}

// Nim/go compatible metrics names
pub struct GossipSubMetrics {
    pub libp2p_peers: Gauge,
    pub libp2p_pubsub_peers: Gauge,
    pub libp2p_pubsub_topics: Gauge,

    pub libp2p_gossipsub_peers_per_topic_mesh: Family<TopicLabels, Gauge>,
    pub libp2p_gossipsub_peers_per_topic_gossipsub: Family<TopicLabels, Gauge>,
    pub libp2p_gossipsub_no_peers_topics: Gauge,
    pub libp2p_gossipsub_low_peers_topics: Gauge,
    pub libp2p_gossipsub_healthy_peers_topics: Gauge,

    pub libp2p_gossipsub_received: Counter,
    pub libp2p_pubsub_messages_published: Family<TopicLabels, Counter>,
    pub libp2p_pubsub_validation_success: Counter,
    pub libp2p_pubsub_validation_failure: Counter,

    pub libp2p_pubsub_received_subscriptions: Family<TopicLabels, Counter>,
    pub libp2p_pubsub_received_unsubscriptions: Family<TopicLabels, Counter>,

    pub d_low: i64,
}

impl GossipSubMetrics {
    pub fn new(registry: &mut Registry, d_low: i64) -> Self {
        let metrics = Self {
            libp2p_peers: Gauge::default(),
            libp2p_pubsub_peers: Gauge::default(),
            libp2p_pubsub_topics: Gauge::default(),

            libp2p_gossipsub_peers_per_topic_mesh: Family::default(),
            libp2p_gossipsub_peers_per_topic_gossipsub: Family::default(),
            libp2p_gossipsub_no_peers_topics: Gauge::default(),
            libp2p_gossipsub_low_peers_topics: Gauge::default(),
            libp2p_gossipsub_healthy_peers_topics: Gauge::default(),

            libp2p_gossipsub_received: Counter::default(),
            libp2p_pubsub_messages_published: Family::default(),
            libp2p_pubsub_validation_success: Counter::default(),
            libp2p_pubsub_validation_failure: Counter::default(),

            libp2p_pubsub_received_subscriptions: Family::default(),
            libp2p_pubsub_received_unsubscriptions: Family::default(),

            d_low,
        };

        // Register metrics
        registry.register(
            "libp2p_peers", 
            "total connected peers", 
            metrics.libp2p_peers.clone()
        );
        registry.register(
            "libp2p_pubsub_peers", 
            "pubsub peer instances", 
            metrics.libp2p_pubsub_peers.clone()
        );
        registry.register(
            "libp2p_pubsub_topics", 
            "pubsub subscribed topics", 
            metrics.libp2p_pubsub_topics.clone()
        );
        registry.register(
            "libp2p_gossipsub_peers_per_topic_mesh", 
            "gossipsub peers per topic in mesh", 
            metrics.libp2p_gossipsub_peers_per_topic_mesh.clone()
        );
        registry.register(
            "libp2p_gossipsub_peers_per_topic_gossipsub", 
            "gossipsub peers per topic in gossipsub", 
            metrics.libp2p_gossipsub_peers_per_topic_gossipsub.clone()
        );
        registry.register(
            "libp2p_gossipsub_no_peers_topics", 
            "number of topics in mesh with no peers", 
            metrics.libp2p_gossipsub_no_peers_topics.clone()
        );
        registry.register(
            "libp2p_gossipsub_low_peers_topics", 
            "number of topics in mesh with at least one but below dlow peers", 
            metrics.libp2p_gossipsub_low_peers_topics.clone()
        );
        registry.register(
            "libp2p_gossipsub_healthy_peers_topics", 
            "number of topics in mesh with at least dlow peers", 
            metrics.libp2p_gossipsub_healthy_peers_topics.clone()
        );
        registry.register(
            "libp2p_gossipsub_received", 
            "number of messages received (deduplicated)", 
            metrics.libp2p_gossipsub_received.clone()
        );
        registry.register(
            "libp2p_pubsub_messages_published", 
            "published messages", 
            metrics.libp2p_pubsub_messages_published.clone()
        );
        registry.register(
            "libp2p_pubsub_validation_success", 
            "pubsub successfully validated messages", 
            metrics.libp2p_pubsub_validation_success.clone()
        );
        registry.register(
            "libp2p_pubsub_validation_failure", 
            "pubsub failed validated messages", 
            metrics.libp2p_pubsub_validation_failure.clone()
        );
        registry.register(
            "libp2p_pubsub_received_subscriptions", 
            "pubsub received subscriptions", 
            metrics.libp2p_pubsub_received_subscriptions.clone()
        );
        registry.register(
            "libp2p_pubsub_received_unsubscriptions", 
            "pubsub received unsubscriptions", 
            metrics.libp2p_pubsub_received_unsubscriptions.clone()
        );

        metrics
    }

    pub fn set_peers(&self, count: i64) {
        self.libp2p_peers.set(count);
    }

    pub fn set_pubsub_peers(&self, count: i64) {
        self.libp2p_pubsub_peers.set(count);
    }

    pub fn set_pubsub_topics(&self, count: i64) {
        self.libp2p_pubsub_topics.set(count);
    }

    pub fn set_mesh_peers(&self, topic: &str, count: i64) {
        self.libp2p_gossipsub_peers_per_topic_mesh
            .get_or_create(&TopicLabels { topic: topic.to_string() })
            .set(count);
    }

    pub fn set_topic_peers(&self, topic: &str, count: i64) {
        self.libp2p_gossipsub_peers_per_topic_gossipsub
            .get_or_create(&TopicLabels { topic: topic.to_string() })
            .set(count);
    }

    pub fn update_health(&self, mesh_counts: &[(String, i64)]) {
        let mut no_peers: i64 = 0;
        let mut low_peers: i64 = 0;
        let mut healthy: i64 = 0;

        for (_topic, count) in mesh_counts {
            if *count == 0 {
                no_peers += 1;
            } else if *count < self.d_low {
                low_peers += 1;
            } else {
                healthy += 1;
            }
        }

        self.libp2p_gossipsub_no_peers_topics.set(no_peers);
        self.libp2p_gossipsub_low_peers_topics.set(low_peers);
        self.libp2p_gossipsub_healthy_peers_topics.set(healthy);
    }

    pub fn inc_received_message(&self) {
        self.libp2p_gossipsub_received.inc();
        self.libp2p_pubsub_validation_success.inc();
    }

    pub fn inc_messages_published(&self, topic: &str) {
        self.libp2p_pubsub_messages_published
            .get_or_create(&TopicLabels { topic: topic.to_string() })
            .inc();
    }

    pub fn inc_received_subscriptions(&self, topic: &str) {
        self.libp2p_pubsub_received_subscriptions
            .get_or_create(&TopicLabels { topic: topic.to_string() })
            .inc();
    }

    pub fn inc_received_unsubscriptions(&self, topic: &str) {
        self.libp2p_pubsub_received_unsubscriptions
            .get_or_create(&TopicLabels { topic: topic.to_string() })
            .inc();
    }
}