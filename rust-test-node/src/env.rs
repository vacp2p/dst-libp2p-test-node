use std::env;
//use std::net::SocketAddr;
use std::sync::Arc;
use std::fs::OpenOptions;
use std::io::Write;
use tokio::time::{interval, Duration};
use prometheus_client::encoding::text::encode;

use warp::{Filter};
use tracing::{info, warn};
//use libp2p::metrics::Registry;

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
    pub service: String,
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

    let service = env::var("SERVICE")
        .unwrap_or_else(|_| "nimp2p-service".to_string());
    
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
        hostname, my_id, network_size, connect_to, chunks, muxer, address, service, in_shadow,
    };
    
    info!(
        "Host info hostname={}, peer={}, muxer={}, inShadow={}, address={}",
        config.hostname, config.my_id, config.muxer, config.in_shadow, config.address
    );
    
    Ok(config)
}

//Prometheus metrics
pub async fn start_metrics_server(registry: Arc<libp2p::metrics::Registry>) {

    let metrics = warp::path!("metrics")
        .and(warp::any().map(move || registry.clone()))
        .map(|registry: Arc<libp2p::metrics::Registry>| {

            let mut buffer = String::new();
            if let Err(e) = encode(&mut buffer, &registry) {
                warn!("Failed to encode metrics: {}", e);
                buffer = "Failed to encode metrics".to_string();
            }
            warp::reply::with_header(
                buffer,
                "Content-Type",
                "text/plain; version=0.0.4",
            )
        });
    
    let addr: std::net::SocketAddr = ([0, 0, 0, 0], PROMETHEUS_PORT).into();
    info!("Prometheus metrics server started at http://0.0.0.0:{}/metrics", PROMETHEUS_PORT);
    tokio::spawn(warp::serve(metrics).run(addr));
}

//log metrics if needed (useful for shadow simulations)
pub async fn store_metrics(
    registry_arc: Arc<libp2p::metrics::Registry>,
    peer_id: usize,
    interval_sec: u64,
) {

    tokio::time::sleep(Duration::from_millis((peer_id as u64) * 60)).await;
    let filename = format!("metrics_pod-{}.txt", peer_id);
    let mut interval = interval(Duration::from_secs(interval_sec));

    loop {
        interval.tick().await;

        let mut buffer = String::new();
        if let Err(e) = encode(&mut buffer, &registry_arc) {
            warn!("Failed to encode metrics for peer {}: {}", peer_id, e);
            continue;
        }

        match OpenOptions::new()
            .create(true)
            .append(true)
            .open(&filename)
        {
            Ok(mut file) => {
                writeln!(file, "\n# Metrics snapshot at {}", chrono::Utc::now()).ok();

                if let Err(e) = file.write_all(buffer.as_bytes()) {
                    warn!("Failed to write metrics for peer {}: {}", peer_id, e);
                } else {
                    info!("Metrics saved for peer {}", peer_id);
                }
            }
            Err(e) => {
                warn!("Failed to open metrics file for peer {}: {}", peer_id, e);
            }
        }
    }
}