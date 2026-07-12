use crate::Client;

impl Client {
    pub async fn announce_multicast(&self) -> crate::error::Result<()> {
        let msg = self.device.to_json()?;
        let addr = self.multicast_addr;
        self.socket.send_to(msg.as_bytes(), addr).await?;
        Ok(())
    }

    pub async fn listen_multicast(&self) -> crate::error::Result<()> {
        let mut buf = [0; 65536];
        tracing::info!("Socket local addr: {:?}", self.socket.local_addr()?);
        tracing::info!("Listening on multicast addr: {}", self.multicast_addr);

        loop {
            match self.socket.recv_from(&mut buf).await {
                Ok((size, src)) => {
                    let received_msg = String::from_utf8_lossy(&buf[..size]);
                    self.process_device(&received_msg, src).await;
                }
                Err(e) => {
                    tracing::warn!("Error receiving message: {}", e);
                    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                }
            }
        }
    }
}
