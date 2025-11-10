use std::env;
use std::net::SocketAddr;
use warp::{Filter};
use tracing::{info};

pub const MY_PORT: u16 = 5000;
pub const HTTP_PUBLISH_PORT: u16 = 8645;
pub const PROMETHEUS_PORT: u16 = 8008;

#[derive(Debug, Clone)]
pub struct PeerConfig {
    pub hostname: String,
    pub my_id: usize,
    pub network_size: usize,
    pub connect_to: usize,
    pub chunks: u32,
    pub muxer: String,
    pub address: String,
    pub in_shadow: bool,
}

pub fn get_peer_details() -> Result<PeerConfig, String> {

    let hostname = match gethostname::gethostname().into_string() {
        Ok(name) => name,
        Err(_) => return Err("Failed to get hostname".to_string()),
    };
    
    let my_id = hostname.split('-').nth(1)
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap();
    
    let network_size = env::var("PEERS")
        .unwrap_or_else(|_| "100".to_string())
        .parse::<usize>()
        .unwrap_or(100);
    
    let connect_to = env::var("CONNECTTO")
        .unwrap_or_else(|_| "10".to_string())
        .parse::<usize>()
        .unwrap_or(10);
    
    let muxer = env::var("MUXER")
        .unwrap_or_else(|_| "yamux".to_string())
        .to_lowercase();
    
    let in_shadow = env::var("SHADOWENV").is_ok();
    
    let address = match muxer.as_str() {
        "quic" => format!("/ip4/0.0.0.0/udp/{}/quic-v1", MY_PORT),
        _ => format!("/ip4/0.0.0.0/tcp/{}", MY_PORT),
    };
    
    let chunks = env::var("FRAGMENTS")
        .unwrap_or_else(|_| "1".to_string())
        .parse::<u32>()
        .unwrap_or(1);
    
    if !["quic", "yamux"].contains(&muxer.as_str()) {
        return Err(format!("Unknown muxer type: {}", muxer));
    }
    
    if connect_to >= network_size {
        return Err(format!("Not enough peers to make target connections. Network size: {}", network_size));
    }
    
    let config = PeerConfig {
        hostname: hostname.clone(),
        my_id,
        network_size,
        connect_to,
        chunks,
        muxer: muxer.clone(),
        address: address.clone(),
        in_shadow,
    };
    
    info!(
        "Host info hostname={}, peer={}, muxer={}, inShadow={}, address={}",
        hostname, my_id, muxer, in_shadow, address
    );
    
    Ok(config)
}

// Metrics server
pub async fn start_metrics_server() {
    let metrics = warp::path!("metrics")
        .map(|| "# Metrics endpoint active\n");
    
    let addr: SocketAddr = ([0, 0, 0, 0], PROMETHEUS_PORT).into();
    info!("Starting metrics HTTP server, serverIp=0.0.0.0, serverPort={}", PROMETHEUS_PORT);
    
    tokio::spawn(async move {
        warp::serve(metrics).run(addr).await;
    });
    
    info!("Metrics HTTP server started, serverIp=0.0.0.0, serverPort={}", PROMETHEUS_PORT);
}
