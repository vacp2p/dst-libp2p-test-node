mod env;

use libp2p::{
    gossipsub::{self, ValidationMode},
    noise,
    swarm::{NetworkBehaviour, SwarmEvent, dial_opts::DialOpts},
    tcp, yamux, Multiaddr,
};
use futures::stream::StreamExt;
use std::{
    collections::{hash_map::DefaultHasher, HashMap},
    error::Error,
    hash::{Hash, Hasher},
    time::Duration,
    sync::Arc,
    net::SocketAddr,
    io::Cursor,
};
use tokio::{
    time::sleep,
    sync::{Mutex, mpsc},
    net::lookup_host,
};
use chrono::{Utc, Timelike};
use byteorder::{LittleEndian, WriteBytesExt, ReadBytesExt};
use rand::{seq::SliceRandom, thread_rng};
use warp::{Filter};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use env::{get_peer_details, PeerConfig, start_metrics_server};

// Global message counter for tracking fragments
lazy_static::lazy_static! {
    static ref MSG_SEEN: Arc<Mutex<HashMap<u64, u32>>> = Arc::new(Mutex::new(HashMap::new()));
}

#[derive(NetworkBehaviour)]
struct MyBehaviour {
    gossipsub: gossipsub::Behaviour,
}

#[derive(Debug, Clone, Deserialize)]
struct PublishRequest {
    topic: String,
    #[serde(rename = "msgSize")]
    msg_size: usize,
    version: i32,
}

#[derive(Debug, Serialize)]
struct PublishResponse {
    status: String,
    message: String,
}

// Message to send from HTTP to swarm
#[derive(Debug)]
struct PublishCommand {
    topic: String,
    msg_size: usize,
    chunks: u32,
    response_tx: tokio::sync::oneshot::Sender<Result<String, String>>,
}

fn msg_id_provider(message: &gossipsub::Message) -> gossipsub::MessageId {
    let mut hasher = DefaultHasher::new();
    message.data.hash(&mut hasher);
    gossipsub::MessageId::from(hasher.finish().to_string())
}

fn create_message_handler(message: gossipsub::Message) {
    let mut cursor = Cursor::new(&message.data[0..8]);
    if let Ok(tx_time) = cursor.read_i64::<LittleEndian>() {
        // warm-up check
        if tx_time >= 1000000 {
            let now = Utc::now();
            let unix_nano = now.timestamp() * 1_000_000_000 + now.nanosecond() as i64;
            println!("{} milliseconds: {}", tx_time, (unix_nano - tx_time) / 1_000_000);
        }
    }
}

async fn publish_new_message(
    cmd: PublishCommand,
    swarm: &mut libp2p::Swarm<MyBehaviour>,
) {
    let now = Utc::now();
    let now_nano = now.timestamp() * 1_000_000_000 + now.nanosecond() as i64;
    
    // Create payload with timestamp
    let mut buffer = vec![0u8; cmd.msg_size / cmd.chunks as usize];
    let mut cursor = &mut buffer[..8];
    cursor.write_i64::<LittleEndian>(now_nano).unwrap();
    
    let topic_hash = gossipsub::IdentTopic::new(&cmd.topic);
    let mut res = 0;
    let mut publish_error = None;
    
    // Publish fragments
    for chunk in 0..cmd.chunks {
        if buffer.len() > 10 {
            buffer[10] = chunk as u8;
        }
        
        match swarm.behaviour_mut().gossipsub.publish(topic_hash.clone(), buffer.clone()) {
            Ok(_) => res += 1,
            Err(e) => {
                warn!("Failed to publish fragment {}: {}", chunk, e);
                publish_error = Some(format!("Failed to publish: {:?}", e));
                break;
            }
        }
    }
    
    // Send response back to HTTP handler
    let response = if let Some(error) = publish_error {
        Err(error)
    } else if res > 0 {
        Ok(format!("Message published at time {}", now))
    } else {
        Err("No fragments published".to_string())
    };
    
    let _ = cmd.response_tx.send(response);
}

// Start HTTP server with channel to communicate with swarm
async fn start_http_server(
    publish_tx: mpsc::Sender<PublishCommand>,
    config: PeerConfig,
) {
    let publish_tx = Arc::new(Mutex::new(publish_tx));
    
    let publish = warp::path!("publish")
        .and(warp::post())
        .and(warp::body::json())
        .and(warp::any().map(move || publish_tx.clone()))
        .and(warp::any().map(move || config.clone()))
        .and_then(|req: PublishRequest, tx: Arc<Mutex<mpsc::Sender<PublishCommand>>>, config: PeerConfig| async move {
            info!("controller message command=/publish, topic={}, size={}, version={}", 
                  req.topic, req.msg_size, req.version);
            
            let (response_tx, response_rx) = tokio::sync::oneshot::channel();
            
            let cmd = PublishCommand {
                topic: req.topic,
                msg_size: req.msg_size,
                chunks: config.chunks,
                response_tx,
            };
            
            // Send command to swarm thread
            if let Err(e) = tx.lock().await.send(cmd).await {
                let response = PublishResponse {
                    status: "error".to_string(),
                    message: format!("Failed to send to swarm: {}", e),
                };
                return Ok::<_, warp::Rejection>(warp::reply::with_status(
                    warp::reply::json(&response),
                    warp::http::StatusCode::INTERNAL_SERVER_ERROR,
                ));
            }
            
            // Wait for response from swarm
            match response_rx.await {
                Ok(Ok(msg)) => {
                    let response = PublishResponse {
                        status: "success".to_string(),
                        message: msg,
                    };
                    Ok(warp::reply::with_status(
                        warp::reply::json(&response),
                        warp::http::StatusCode::OK,
                    ))
                }
                Ok(Err(e)) => {
                    let response = PublishResponse {
                        status: "error".to_string(),
                        message: e,
                    };
                    Ok(warp::reply::with_status(
                        warp::reply::json(&response),
                        warp::http::StatusCode::INTERNAL_SERVER_ERROR,
                    ))
                }
                Err(_) => {
                    let response = PublishResponse {
                        status: "error".to_string(),
                        message: "Channel closed".to_string(),
                    };
                    Ok(warp::reply::with_status(
                        warp::reply::json(&response),
                        warp::http::StatusCode::INTERNAL_SERVER_ERROR,
                    ))
                }
            }
        });
    
    let routes = publish.or(warp::path::end().map(|| "Not Found"));
    let addr: SocketAddr = ([0, 0, 0, 0], env::HTTP_PUBLISH_PORT).into();
    info!("starting http server httpPort={}", env::HTTP_PUBLISH_PORT);
    warp::serve(routes).run(addr).await;
}

fn configure_gossipsub_params() -> gossipsub::Config {

    gossipsub::ConfigBuilder::default()
        .validation_mode(ValidationMode::Permissive)
        .message_id_fn(msg_id_provider)
        .flood_publish(true)
        .heartbeat_interval(Duration::from_secs(1))
        .prune_backoff(Duration::from_secs(60))
        .gossip_factor(0.25)
        .mesh_n(6)
        .mesh_n_low(4)
        .mesh_n_high(8)
        .mesh_outbound_min(3)
        .gossip_lazy(6)
        .opportunistic_graft_peers(0)
        .build()
        .expect("Valid gossipsub configuration")
}

fn subscribe_gossipsub_topic(
    swarm: &mut libp2p::Swarm<MyBehaviour>,
    topic_name: &str
) -> Result<gossipsub::IdentTopic, Box<dyn Error>> {

    let topic = gossipsub::IdentTopic::new(topic_name);
    swarm.behaviour_mut()
        .gossipsub
        .subscribe(&topic)?;
    
    let topic_params = gossipsub::TopicScoreParams {
        topic_weight: 1.0,
        first_message_deliveries_weight: 1.0,
        first_message_deliveries_cap: 30.0,
        first_message_deliveries_decay: 0.9,
        ..Default::default()
    };
    

    match swarm.behaviour_mut()
        .gossipsub
        .set_topic_params(topic.clone(), topic_params) {
        Ok(_) => {
            info!("Successfully set topic scoring parameters for '{}'", topic_name);
        }
        Err(e) => {
            warn!("Could not set topic scoring parameters for '{}': {:?}", topic_name, e);
        }
    }

    Ok(topic)
}

async fn resolve_address(t_address: &str, in_shadow: bool, muxer: &str) -> Result<Vec<String>, Box<dyn Error>> {

    let mut addrs = Vec::new();

    loop {
        match lookup_host(t_address).await {
            Ok(lookup_result) => {
                for addr in lookup_result {
                    if addr.is_ipv4() {
                        let formatted_addr = match muxer {
                            "quic" => format!("/ip4/{}/udp/{}/quic-v1", addr.ip(), env::MY_PORT),
                            _ => format!("/ip4/{}/tcp/{}", addr.ip(), env::MY_PORT),
                        };
                        addrs.push(formatted_addr.clone());
                        info!("Address resolved, tAddress = {}, resolved = {}", t_address, formatted_addr.clone());                        
                    }
                }
                return Ok(addrs);
            }
            Err(e) => {
                warn!("Failed to resolve address {}: {:?}", t_address, e);
                if in_shadow {
                    return Err(Box::new(e));
                }
                sleep(Duration::from_secs(15)).await;
            }
        }
    }
}

async fn connect_gossipsub_peers(
    swarm: &mut libp2p::Swarm<MyBehaviour>,
    config: &PeerConfig
) -> Result<u32, Box<dyn Error>> {

    let mut rng = thread_rng();

    let t_addresses: Vec<String> = if config.in_shadow {
        let mut peers: Vec<usize> = (0..config.network_size)
            .filter(|&id| id != config.my_id)
            .collect();
        let limit = std::cmp::min(config.connect_to * 2, peers.len());

        peers.shuffle(&mut rng);
        peers[..limit]
            .iter()
            .map(|id| format!("pod-{}:{}", id, env::MY_PORT))
            .collect()
    } else {
        vec![format!("nimp2p-service:{}", env::MY_PORT)]
    };
    
    let mut resolved_addrs = Vec::new();
    for t_address in &t_addresses {
        match resolve_address(t_address, config.in_shadow, &config.muxer).await {
            Ok(addrs) => resolved_addrs.extend(addrs),
            Err(e) => warn!("Failed to resolve {}: {}", t_address, e),
        }
    }

    resolved_addrs.shuffle(&mut rng);
    let mut connected = 0u32;

    for addr in resolved_addrs {
        if connected > config.connect_to as u32{
            break;
        }
        info!("now dialing {}, parsed is {:?}", addr, addr.parse::<Multiaddr>());
        match swarm.dial(
            DialOpts::unknown_peer_id()
                .address(addr.parse().unwrap())
                .build()
        ) {
            Ok(_) => {
                connected += 1;
                info!("Connected!: current connections: connected {}, target {}", connected, config.connect_to);
            }
            Err(e) => {
                warn!("Failed to dial : , theirAddress {}, error {:?}", addr, e);
            }
        }
    }

    //handle connection events
    let timeout = tokio::time::Instant::now() + Duration::from_secs(20);
    while tokio::time::Instant::now() < timeout {
        if let Ok(Some(event)) = tokio::time::timeout(
            Duration::from_millis(100), 
            swarm.next()
        ).await {
            match event {
                SwarmEvent::ConnectionEstablished { .. } => {}
                _ => {}
            }
        }
    }
    
    if connected == 0 {
        Err("Failed to connect any peers".into())
    } else {
        if connected < config.connect_to as u32 {
            warn!("Connected to fewer peers than target: connected {}, target {}", connected, config.connect_to);
        }
        Ok(connected)
    }
}


#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_ansi(false)
        .init();
    
    let config = get_peer_details()?;

    let mut swarm = if config.muxer == "quic" {
        //quic transport
        libp2p::SwarmBuilder::with_new_identity()
            .with_tokio()
            .with_quic()
            .with_behaviour(|key| {
                let gossipsub_config = configure_gossipsub_params();
                let gossipsub = gossipsub::Behaviour::new(
                    gossipsub::MessageAuthenticity::Signed(key.clone()),
                    gossipsub_config,
                )?; 
                Ok(MyBehaviour { gossipsub })
            })?
            .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
            .build()
    } else {
        //only yamux is supported. mplex is obsolete
        libp2p::SwarmBuilder::with_new_identity()
            .with_tokio()
            .with_tcp(
                tcp::Config::default().nodelay(true),
                noise::Config::new,
                yamux::Config::default,
            )?
            .with_behaviour(|key| {
                let gossipsub_config = configure_gossipsub_params();
                let gossipsub = gossipsub::Behaviour::new(
                    gossipsub::MessageAuthenticity::Signed(key.clone()),
                    gossipsub_config,
                )?; 
                Ok(MyBehaviour { gossipsub })
            })?
            .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
            .build()
    };
    
    let topic = subscribe_gossipsub_topic(&mut swarm, "test")?;
    
    // Start listening
    swarm.listen_on(config.address.parse()?)?;
    
    // Start metrics server
    start_metrics_server().await;
    
    // Wait for node initialization before connecting with peers
    sleep(Duration::from_secs(60)).await;
    let connected = connect_gossipsub_peers(&mut swarm, &config).await?;
    
    let mesh_size = swarm.behaviour().gossipsub.mesh_peers(&topic.hash()).count();
    let peers_connected = swarm.behaviour().gossipsub.all_peers().count();
    info!("Mesh details meshSize={}, peersConnected={}, dialed={}", mesh_size, peers_connected, connected);
    
    // Create channel for HTTP/swarm communication
    info!("Starting listening endpoint for publish controller");
    let (publish_tx, mut publish_rx) = mpsc::channel::<PublishCommand>(10);
    
    // Start HTTP server
    let config_http = config.clone();
    tokio::spawn(async move {
        start_http_server(publish_tx, config_http).await;
    });
    
    loop {
        tokio::select! {
            Some(cmd) = publish_rx.recv() => {
                // Handle publish command from HTTP
                publish_new_message(cmd, &mut swarm).await;
            }
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::Behaviour(MyBehaviourEvent::Gossipsub(gossipsub::Event::Message {
                        message,
                        ..
                    })) => {
                        create_message_handler(message);
                    }
                    SwarmEvent::Behaviour(MyBehaviourEvent::Gossipsub(gossipsub::Event::Subscribed {
                        peer_id,
                        ..
                    })) => {
                        info!("Peer {} subscribed to topic", peer_id);
                    }
                    SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                        info!("Connection established with {}", peer_id);
                    }
                    SwarmEvent::IncomingConnectionError { send_back_addr, error, .. } => {
                        warn!("Incoming connection error from {}: {}", send_back_addr, error);
                    }
                    SwarmEvent::OutgoingConnectionError { error, .. } => {
                        warn!("Outgoing connection error: {}", error);
                    }
                    _ => {}
                }
            }
        }
    }
}