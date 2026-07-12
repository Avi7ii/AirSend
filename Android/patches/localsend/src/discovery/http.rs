use std::net::SocketAddr;
use std::time::Duration;

use axum::{
    extract::{ConnectInfo, State},
    Extension, Json,
};

use crate::{
    models::device::DeviceInfo, ports::TRANSFER_PORT, remember_peer_entry, Client, PeerMap,
};

impl Client {
    pub async fn announce_http(
        &self,
        ip: Option<SocketAddr>,
        protocol: &str,
    ) -> crate::error::Result<()> {
        if let Some(ip) = ip {
            let url = format!("{}://{}/api/localsend/v2/register", protocol, ip);
            // Discovery 流量不应与真正的传输复用长连接，否则换网后会把
            // /register、/prepare-upload、/upload 串在同一条 keep-alive 通道上，
            // 导致 30s 级别的队头阻塞。
            let response = self
                .http_client
                .post(&url)
                .header("Connection", "close")
                .timeout(Duration::from_secs(1))
                .json(&self.device)
                .send()
                .await?;
            let _ = response.bytes().await?;
        }
        Ok(())
    }

    pub async fn announce_http_legacy(&self) -> crate::error::Result<()> {
        // send the reqwest to all local ip addresses from 192.168.0.0 to 192.168.255.255
        let mut address_list = Vec::new();
        for j in 0..256 {
            for k in 0..256 {
                address_list.push(format!("192.168.{:03}.{}:{}", j, k, TRANSFER_PORT));
            }
        }

        let protocol = &self.device.protocol;
        for ip in address_list {
            let url = format!("{}://{}/api/localsend/v2/register", protocol, ip);
            self.http_client
                .post(&url)
                .json(&self.device)
                .send()
                .await?;
        }
        Ok(())
    }
}

pub async fn register_device(
    State(peers): State<PeerMap>,
    Extension(client): Extension<DeviceInfo>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(device): Json<DeviceInfo>,
) -> Json<DeviceInfo> {
    let mut addr = addr;
    addr.set_port(device.port);
    let mut peers = peers.lock().await;
    remember_peer_entry(&mut peers, addr, device.clone());
    Json(client)
}
