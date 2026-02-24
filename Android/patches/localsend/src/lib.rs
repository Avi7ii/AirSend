pub mod discovery;
pub mod error;
pub mod models;
pub mod server;
pub mod transfer;

use crate::models::device::DeviceInfo;
use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use tokio::net::UdpSocket;
use tokio::task::JoinHandle;
use std::sync::Arc;
use tokio::sync::Mutex;
use transfer::session::Session;

#[derive(Clone)]
pub struct Client {
    pub device: DeviceInfo,
    pub socket: Arc<UdpSocket>,
    pub multicast_addr: SocketAddrV4,
    pub port: u16,
    pub peers: Arc<Mutex<HashMap<String, (SocketAddr, DeviceInfo)>>>,
    pub sessions: Arc<Mutex<HashMap<String, Session>>>, // Session ID to Session
    pub http_client: reqwest::Client,
    pub download_dir: String,
}

impl Client {
    pub async fn default() -> crate::error::Result<Self> {
        let device = DeviceInfo::default();
        let socket = UdpSocket::bind("0.0.0.0:53317").await?;
        socket.set_multicast_loop_v4(true)?;
        socket.set_multicast_ttl_v4(255)?;
        socket.join_multicast_v4(Ipv4Addr::new(224, 0, 0, 167), Ipv4Addr::new(0, 0, 0, 0))?;
        let multicast_addr = SocketAddrV4::new(Ipv4Addr::new(224, 0, 0, 167), 53317);
        let port = 53317;
        let peers = Arc::new(Mutex::new(HashMap::new()));
        let http_client = reqwest::Client::new();
        let sessions = Arc::new(Mutex::new(HashMap::new()));
        let download_dir = "/sdcard/Download/AirSend".to_string();

        Ok(Self {
            device,
            socket: socket.into(),
            multicast_addr,
            port,
            peers,
            http_client,
            sessions,
            download_dir,
        })
    }

    pub async fn with_config(info: DeviceInfo, port: u16, download_dir: String) -> crate::error::Result<Self>{
        let socket = UdpSocket::bind(format!("0.0.0.0:{}", port.clone())).await?;
        socket.set_multicast_loop_v4(true)?;
        socket.set_multicast_ttl_v4(255)?;
        socket.join_multicast_v4(Ipv4Addr::new(224, 0, 0, 167), Ipv4Addr::new(0, 0, 0, 0))?;
        let multicast_addr = SocketAddrV4::new(Ipv4Addr::new(224, 0, 0, 167), port.clone());
        let peers = Arc::new(Mutex::new(HashMap::new()));
        let http_client = reqwest::Client::new();
        let sessions = Arc::new(Mutex::new(HashMap::new()));

        Ok(Self {
            device: info,
            socket: socket.into(),
            multicast_addr,
            port,
            peers,
            http_client,
            sessions,
            download_dir,
        })

    }

    pub async fn start(&self) -> crate::error::Result<(JoinHandle<()>, JoinHandle<()>, JoinHandle<()>)> {
        let server_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                if let Err(e) = client.start_http_server().await {
                    eprintln!("HTTP server error: {}", e);
                }
            })
        };

        let udp_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                if let Err(e) = client.listen_multicast().await {
                    eprintln!("UDP listener error: {}", e);
                }
            })
        };

        let announcement_handle = {
            let client = self.clone();
            tokio::spawn(async move {
                loop {
                    if let Err(e) = client.announce(None).await {
                        eprintln!("Announcement error: {}", e);
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                }
            })
        };

        Ok((server_handle, udp_handle, announcement_handle))
    }

    pub async fn refresh_peers(&self) {
        let mut peers = self.peers.lock().await;
        peers.clear();
    }
}
