use std::net::SocketAddr;
use std::time::Duration;

use axum::{
    extract::{ConnectInfo, State},
    Extension, Json,
};

use crate::{
    models::device::DeviceInfo, ports::TRANSFER_PORT, remember_peer_entry, Client, PeerMap,
};

const MAC_TRANSFER_PORT: u16 = 53318;

fn announcement_port_candidates(advertised_port: u16) -> Vec<u16> {
    let mut ports = vec![advertised_port];
    for port in [MAC_TRANSFER_PORT, TRANSFER_PORT] {
        if !ports.contains(&port) {
            ports.push(port);
        }
    }
    ports
}

impl Client {
    pub async fn announce_http(
        &self,
        ip: Option<SocketAddr>,
        protocol: &str,
    ) -> crate::error::Result<()> {
        if let Some(ip) = ip {
            let mut last_error = None;
            for port in announcement_port_candidates(ip.port()) {
                let candidate = SocketAddr::new(ip.ip(), port);
                let url = format!("{}://{}/api/localsend/v2/register", protocol, candidate);
                // Discovery 流量不应与真正的传输复用长连接，否则换网后会把
                // /register、/prepare-upload、/upload 串在同一条 keep-alive 通道上。
                let response = self
                    .http_client
                    .post(&url)
                    .header("Connection", "close")
                    .timeout(Duration::from_secs(1))
                    .json(&self.device)
                    .send()
                    .await
                    .and_then(reqwest::Response::error_for_status);
                let response = match response {
                    Ok(response) => response,
                    Err(error) => {
                        last_error = Some(error);
                        continue;
                    }
                };
                let remote = response.json::<DeviceInfo>().await?;
                let mut remote_addr = candidate;
                remote_addr.set_port(remote.port);
                let mut peers = self.peers.lock().await;
                remember_peer_entry(&mut peers, remote_addr, remote);
                return Ok(());
            }
            if let Some(error) = last_error {
                return Err(error.into());
            }
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

#[cfg(test)]
mod tests {
    use super::announcement_port_candidates;

    #[test]
    fn announcement_fallback_covers_mac_and_android_transfer_ports() {
        assert_eq!(announcement_port_candidates(53319), vec![53319, 53318]);
        assert_eq!(announcement_port_candidates(53318), vec![53318, 53319]);
        assert_eq!(
            announcement_port_candidates(53317),
            vec![53317, 53318, 53319]
        );
    }
}
