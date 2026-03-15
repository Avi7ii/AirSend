use std::net::SocketAddr;

use crate::{models::device::DeviceInfo, remember_peer_entry, Client};

pub mod http;
pub mod multicast;

impl Client {
    pub async fn announce(&self, socket: Option<SocketAddr>) -> crate::error::Result<()> {
        self.announce_http(socket, &self.device.protocol).await?;
        self.announce_multicast().await?;
        Ok(())
    }

    async fn process_device(&self, message: &str, src: SocketAddr ) {
        if self.maybe_handle_campus_message(message).await {
            return;
        }
        if let Ok(device) = serde_json::from_str::<DeviceInfo>(message) {
            if device.fingerprint == self.device.fingerprint {
                return;
            }

            let mut src = src;
            src.set_port(device.port); // Update the port to the one the device sent

            self.maybe_pin_peer_neighbor(src.ip(), device.mac_address.as_deref()).await;

            let mut peers = self.peers.lock().await;
            remember_peer_entry(&mut peers, src, device.clone());

            if device.announce != Some(true) {
                return;
            }

            // Announce in return upon receiving a valid device message and it wants announcements
            if let Err(e) = self.announce_multicast().await {
                eprintln!("Error during multicast announcement: {}", e);
            }
            if let Err(e) = self.announce_http(Some(src), &device.protocol).await {
                eprintln!("Error during HTTP announcement: {}", e);
            };
        } else {
            eprintln!("Received invalid message: {}", message);
        }
    }
}
