use std::{collections::HashMap, net::SocketAddr, sync::Arc};
use tokio::sync::Mutex;

use axum::{extract::{ConnectInfo, State}, Extension, Json};

use crate::{models::device::DeviceInfo, Client};

impl Client {
    pub async fn announce_http(&self, ip: Option<SocketAddr>, protocol: &str) -> crate::error::Result<()> {
        if let Some(ip) = ip {
            let url = format!("{}://{}/api/localsend/v2/register", protocol, ip);
            // 使用 Client 实例自己的 http_client (这已经被我们在 main.rs 里注入了不安全证书配置)
            self.http_client.post(&url).json(&self.device).send().await?;
        }
        Ok(())
    }

    pub async fn announce_http_legacy(&self) -> crate::error::Result<()> {
        // send the reqwest to all local ip addresses from 192.168.0.0 to 192.168.255.255
        let mut address_list = Vec::new();
        for j in 0..256 {
            for k in 0..256 {
                address_list.push(format!("192.168.{:03}.{}:53317", j, k));
            }
        }

        let protocol = &self.device.protocol;
        for ip in address_list {
            let url = format!("{}://{}/api/localsend/v2/register", protocol, ip);
            self.http_client.post(&url).json(&self.device).send().await?;
        }
        Ok(())
    }
}

pub async fn register_device(
    State(peers): State<Arc<Mutex<HashMap<String, (SocketAddr, DeviceInfo)>>>>,
    Extension(client): Extension<DeviceInfo>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(device): Json<DeviceInfo>,
) -> Json<DeviceInfo> {
    let mut addr = addr;
    addr.set_port(device.port);
    peers.lock().await.insert(device.fingerprint.clone(), (addr, device.clone()));
    Json(client)
}
