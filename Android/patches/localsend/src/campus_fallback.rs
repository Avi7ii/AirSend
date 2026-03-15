use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::time::{sleep, Instant};
use uuid::Uuid;

use crate::{models::device::DeviceInfo, Client};

const CAMPUS_MARKER: u8 = 1;
const CHUNK_SIZE: usize = 600;
const WINDOW_SIZE: usize = 24;
const MAX_FALLBACK_BYTES: usize = 20 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CampusEnvelope {
    campus_fallback: u8,
    #[serde(rename = "type")]
    kind: String,
    transfer_id: String,
    sender_id: String,
    target_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    sender_alias: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total_size: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chunk_size: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total_chunks: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    window_size: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    window_start: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    index: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    payload: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    missing: Option<Vec<usize>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    success: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

impl CampusEnvelope {
    fn base(kind: &str, transfer_id: String, sender_id: String, target_id: String) -> Self {
        Self {
            campus_fallback: CAMPUS_MARKER,
            kind: kind.to_string(),
            transfer_id,
            sender_id,
            target_id,
            sender_alias: None,
            file_name: None,
            file_type: None,
            total_size: None,
            chunk_size: None,
            total_chunks: None,
            window_size: None,
            window_start: None,
            count: None,
            index: None,
            payload: None,
            missing: None,
            success: None,
            message: None,
        }
    }
}

#[derive(Debug, Clone)]
enum OutgoingWindowResult {
    Ack,
    Nack(Vec<usize>),
}

#[derive(Debug, Clone, Default)]
struct OutgoingTransferState {
    accepted: bool,
    window_results: HashMap<usize, OutgoingWindowResult>,
    completion: Option<Result<(), String>>,
}

#[derive(Debug, Clone)]
struct IncomingTransferState {
    sender_id: String,
    sender_alias: String,
    file_name: String,
    file_type: String,
    total_size: usize,
    total_chunks: usize,
    window_size: usize,
    next_window_start: usize,
    assembled: Vec<u8>,
    window_chunks: HashMap<usize, Vec<u8>>,
}

#[derive(Debug, Default)]
pub struct CampusFallbackState {
    outgoing: HashMap<String, OutgoingTransferState>,
    incoming: HashMap<String, IncomingTransferState>,
}

impl Client {
    pub async fn send_campus_text(&self, peer_id: &str, text: &str) -> crate::error::Result<()> {
        self.send_campus_payload(peer_id, "clipboard.txt", "text/plain", text.as_bytes())
            .await
    }

    pub async fn send_campus_file(
        &self,
        peer_id: &str,
        file_name: &str,
        file_type: &str,
        bytes: &[u8],
    ) -> crate::error::Result<()> {
        self.send_campus_payload(peer_id, file_name, file_type, bytes).await
    }

    pub async fn maybe_handle_campus_message(&self, message: &str) -> bool {
        let Ok(envelope) = serde_json::from_str::<CampusEnvelope>(message) else {
            return false;
        };
        if envelope.campus_fallback != CAMPUS_MARKER {
            return false;
        }

        eprintln!(
            "Campus packet rx type={} transfer={} from={} to={}",
            envelope.kind, envelope.transfer_id, envelope.sender_id, envelope.target_id
        );
        match self.handle_campus_message(envelope).await {
            Ok(()) => {}
            Err(err) => eprintln!("Campus fallback error: {}", err),
        }
        true
    }

    pub async fn send_campus_payload(
        &self,
        peer_id: &str,
        file_name: &str,
        file_type: &str,
        bytes: &[u8],
    ) -> crate::error::Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        if bytes.len() > MAX_FALLBACK_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("Campus fallback only supports files up to {} bytes", MAX_FALLBACK_BYTES),
            )
            .into());
        }

        let transfer_id = Uuid::new_v4().to_string();
        let total_chunks = bytes.len().div_ceil(CHUNK_SIZE);

        {
            let mut campus = self.campus_fallback.lock().await;
            campus
                .outgoing
                .insert(transfer_id.clone(), OutgoingTransferState::default());
        }

        let prepare = CampusEnvelope {
            sender_alias: Some(self.device.alias.clone()),
            file_name: Some(file_name.to_string()),
            file_type: Some(file_type.to_string()),
            total_size: Some(bytes.len()),
            chunk_size: Some(CHUNK_SIZE),
            total_chunks: Some(total_chunks),
            window_size: Some(WINDOW_SIZE),
            ..CampusEnvelope::base(
                "prepare",
                transfer_id.clone(),
                self.device.fingerprint.clone(),
                peer_id.to_string(),
            )
        };

        let accepted = self.await_prepare_accept(&transfer_id, &prepare).await?;
        if !accepted {
            self.cleanup_campus_outgoing(&transfer_id).await;
            return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "Campus fallback accept timed out").into());
        }

        for window_start in (0..total_chunks).step_by(WINDOW_SIZE) {
            let window_end = usize::min(window_start + WINDOW_SIZE, total_chunks);
            let mut pending: Vec<usize> = (window_start..window_end).collect();
            let mut attempts = 0;

            while !pending.is_empty() {
                attempts += 1;
                if attempts > 6 {
                    self.cleanup_campus_outgoing(&transfer_id).await;
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        format!("Campus fallback window {} failed", window_start),
                    )
                    .into());
                }

                for &chunk_index in &pending {
                    let start = chunk_index * CHUNK_SIZE;
                    let end = usize::min(start + CHUNK_SIZE, bytes.len());
                    let mut chunk = CampusEnvelope::base(
                        "chunk",
                        transfer_id.clone(),
                        self.device.fingerprint.clone(),
                        peer_id.to_string(),
                    );
                    chunk.window_start = Some(window_start);
                    chunk.index = Some(chunk_index);
                    chunk.payload = Some(BASE64.encode(&bytes[start..end]));
                    self.send_campus_message(&chunk).await?;
                    sleep(Duration::from_millis(2)).await;
                }

                let mut window_end_msg = CampusEnvelope::base(
                    "windowEnd",
                    transfer_id.clone(),
                    self.device.fingerprint.clone(),
                    peer_id.to_string(),
                );
                window_end_msg.window_start = Some(window_start);
                window_end_msg.count = Some(window_end - window_start);
                self.send_campus_message(&window_end_msg).await?;

                match self.await_window_result(&transfer_id, window_start).await? {
                    OutgoingWindowResult::Ack => {
                        pending.clear();
                    }
                    OutgoingWindowResult::Nack(missing) => {
                        pending = missing;
                    }
                }
            }
        }

        let finish = CampusEnvelope::base(
            "finish",
            transfer_id.clone(),
            self.device.fingerprint.clone(),
            peer_id.to_string(),
        );
        self.send_campus_message(&finish).await?;
        self.await_completion(&transfer_id).await?;
        self.cleanup_campus_outgoing(&transfer_id).await;
        Ok(())
    }

    async fn handle_campus_message(&self, envelope: CampusEnvelope) -> crate::error::Result<()> {
        match envelope.kind.as_str() {
            "prepare" => self.handle_campus_prepare(envelope).await,
            "chunk" => self.handle_campus_chunk(envelope).await,
            "windowEnd" => self.handle_campus_window_end(envelope).await,
            "finish" => self.handle_campus_finish(envelope).await,
            "accept" | "windowAck" | "windowNack" | "complete" => {
                self.handle_campus_outgoing_event(envelope).await;
                Ok(())
            }
            _ => Ok(()),
        }
    }

    async fn handle_campus_prepare(&self, envelope: CampusEnvelope) -> crate::error::Result<()> {
        if envelope.target_id != self.device.fingerprint {
            return Ok(());
        }
        let file_name = envelope.file_name.unwrap_or_else(|| "CampusTransfer.bin".to_string());
        let file_type = envelope
            .file_type
            .unwrap_or_else(|| "application/octet-stream".to_string());
        let total_size = envelope.total_size.unwrap_or(0);
        let total_chunks = envelope.total_chunks.unwrap_or(0);
        let window_size = envelope.window_size.unwrap_or(WINDOW_SIZE);
        if total_size == 0 || total_size > MAX_FALLBACK_BYTES || total_chunks == 0 {
            return Ok(());
        }

        let state = IncomingTransferState {
            sender_id: envelope.sender_id.clone(),
            sender_alias: envelope.sender_alias.unwrap_or_else(|| "Campus Sender".to_string()),
            file_name,
            file_type,
            total_size,
            total_chunks,
            window_size,
            next_window_start: 0,
            assembled: Vec::with_capacity(total_size),
            window_chunks: HashMap::new(),
        };

        {
            let mut campus = self.campus_fallback.lock().await;
            campus.incoming.insert(envelope.transfer_id.clone(), state);
        }

        let accept = CampusEnvelope::base(
            "accept",
            envelope.transfer_id,
            self.device.fingerprint.clone(),
            envelope.sender_id,
        );
        self.send_campus_message(&accept).await
    }

    async fn handle_campus_chunk(&self, envelope: CampusEnvelope) -> crate::error::Result<()> {
        if envelope.target_id != self.device.fingerprint {
            return Ok(());
        }
        let Some(index) = envelope.index else {
            return Ok(());
        };
        let Some(payload) = envelope.payload else {
            return Ok(());
        };
        let decoded = BASE64
            .decode(payload.as_bytes())
            .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err.to_string()))?;

        let mut campus = self.campus_fallback.lock().await;
        if let Some(state) = campus.incoming.get_mut(&envelope.transfer_id) {
            state.window_chunks.entry(index).or_insert(decoded);
        }
        Ok(())
    }

    async fn handle_campus_window_end(&self, envelope: CampusEnvelope) -> crate::error::Result<()> {
        if envelope.target_id != self.device.fingerprint {
            return Ok(());
        }
        let window_start = envelope.window_start.unwrap_or(0);
        let count = envelope.count.unwrap_or(0);
        let mut missing = Vec::new();
        let mut ack_target = None;

        {
            let mut campus = self.campus_fallback.lock().await;
            let Some(state) = campus.incoming.get_mut(&envelope.transfer_id) else {
                return Ok(());
            };
            let window_end = usize::min(window_start + count, state.total_chunks);
            for index in window_start..window_end {
                if !state.window_chunks.contains_key(&index) {
                    missing.push(index);
                }
            }

            if missing.is_empty() && state.next_window_start == window_start {
                for index in window_start..window_end {
                    if let Some(bytes) = state.window_chunks.remove(&index) {
                        state.assembled.extend_from_slice(&bytes);
                    }
                }
                state.next_window_start = window_end;
            }

            ack_target = Some(state.sender_id.clone());
        }

        let Some(target_id) = ack_target else {
            return Ok(());
        };

        let mut response = CampusEnvelope::base(
            if missing.is_empty() { "windowAck" } else { "windowNack" },
            envelope.transfer_id,
            self.device.fingerprint.clone(),
            target_id,
        );
        response.window_start = Some(window_start);
        if !missing.is_empty() {
            response.missing = Some(missing);
        }
        self.send_campus_message(&response).await
    }

    async fn handle_campus_finish(&self, envelope: CampusEnvelope) -> crate::error::Result<()> {
        if envelope.target_id != self.device.fingerprint {
            return Ok(());
        }

        let outcome = {
            let mut campus = self.campus_fallback.lock().await;
            match campus.incoming.remove(&envelope.transfer_id) {
                Some(state) if state.assembled.len() == state.total_size && state.next_window_start == state.total_chunks => {
                    Ok(state)
                }
                Some(state) => Err(format!(
                    "Incomplete campus transfer from {}: got {} / {} bytes",
                    state.sender_alias,
                    state.assembled.len(),
                    state.total_size
                )),
                None => Err("Missing campus transfer state".to_string()),
            }
        };

        let mut complete = CampusEnvelope::base(
            "complete",
            envelope.transfer_id,
            self.device.fingerprint.clone(),
            envelope.sender_id,
        );

        match outcome {
            Ok(state) => {
                if let Err(err) = self.persist_campus_bytes(&state.file_name, &state.file_type, &state.assembled).await {
                    complete.success = Some(false);
                    complete.message = Some(err.to_string());
                } else {
                    complete.success = Some(true);
                }
            }
            Err(err) => {
                complete.success = Some(false);
                complete.message = Some(err);
            }
        }

        self.send_campus_message(&complete).await
    }

    async fn handle_campus_outgoing_event(&self, envelope: CampusEnvelope) {
        if envelope.target_id != self.device.fingerprint {
            return;
        }

        let mut campus = self.campus_fallback.lock().await;
        let Some(state) = campus.outgoing.get_mut(&envelope.transfer_id) else {
            return;
        };

        match envelope.kind.as_str() {
            "accept" => state.accepted = true,
            "windowAck" => {
                if let Some(window_start) = envelope.window_start {
                    state.window_results.insert(window_start, OutgoingWindowResult::Ack);
                }
            }
            "windowNack" => {
                if let Some(window_start) = envelope.window_start {
                    state.window_results.insert(
                        window_start,
                        OutgoingWindowResult::Nack(envelope.missing.unwrap_or_default()),
                    );
                }
            }
            "complete" => {
                let result = if envelope.success.unwrap_or(false) {
                    Ok(())
                } else {
                    Err(envelope.message.unwrap_or_else(|| "Campus transfer failed".to_string()))
                };
                state.completion = Some(result);
            }
            _ => {}
        }
    }

    async fn send_campus_message(&self, message: &CampusEnvelope) -> crate::error::Result<()> {
        let payload = serde_json::to_vec(message)?;
        eprintln!(
            "Campus packet tx type={} transfer={} from={} to={}",
            message.kind, message.transfer_id, message.sender_id, message.target_id
        );
        self.socket.send_to(&payload, self.multicast_addr).await?;
        let broadcast_addr = std::net::SocketAddrV4::new(std::net::Ipv4Addr::new(255, 255, 255, 255), self.discovery_port);
        let _ = self.socket.send_to(&payload, broadcast_addr).await;
        Ok(())
    }

    async fn await_prepare_accept(
        &self,
        transfer_id: &str,
        prepare: &CampusEnvelope,
    ) -> crate::error::Result<bool> {
        for _ in 0..4 {
            self.send_campus_message(prepare).await?;
            let started = Instant::now();
            while started.elapsed() < Duration::from_millis(900) {
                {
                    let campus = self.campus_fallback.lock().await;
                    if campus
                        .outgoing
                        .get(transfer_id)
                        .map(|state| state.accepted)
                        .unwrap_or(false)
                    {
                        return Ok(true);
                    }
                }
                sleep(Duration::from_millis(100)).await;
            }
        }
        Ok(false)
    }

    async fn await_window_result(
        &self,
        transfer_id: &str,
        window_start: usize,
    ) -> crate::error::Result<OutgoingWindowResult> {
        let started = Instant::now();
        while started.elapsed() < Duration::from_millis(1600) {
            {
                let mut campus = self.campus_fallback.lock().await;
                if let Some(state) = campus.outgoing.get_mut(transfer_id) {
                    if let Some(result) = state.window_results.remove(&window_start) {
                        return Ok(result);
                    }
                }
            }
            sleep(Duration::from_millis(80)).await;
        }

        Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            format!("Timed out waiting for campus window {}", window_start),
        )
        .into())
    }

    async fn await_completion(&self, transfer_id: &str) -> crate::error::Result<()> {
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(6) {
            {
                let campus = self.campus_fallback.lock().await;
                if let Some(state) = campus.outgoing.get(transfer_id) {
                    if let Some(result) = &state.completion {
                        return result.clone().map_err(|message| {
                            std::io::Error::new(std::io::ErrorKind::Other, message).into()
                        });
                    }
                }
            }
            sleep(Duration::from_millis(120)).await;
        }

        Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "Timed out waiting for campus completion",
        )
        .into())
    }

    async fn cleanup_campus_outgoing(&self, transfer_id: &str) {
        let mut campus = self.campus_fallback.lock().await;
        campus.outgoing.remove(transfer_id);
    }

    async fn persist_campus_bytes(
        &self,
        file_name: &str,
        file_type: &str,
        bytes: &[u8],
    ) -> crate::error::Result<()> {
        if file_type == "text/plain" && file_name == "clipboard.txt" {
            let mut stream = UnixStream::connect("\0airsend_app_ipc").await.map_err(|err| {
                std::io::Error::new(std::io::ErrorKind::ConnectionRefused, err.to_string())
            })?;
            stream.write_all(bytes).await?;
            stream.shutdown().await?;
            return Ok(());
        }

        let actual_dir = if file_type.starts_with("image/") || file_type.starts_with("video/") {
            "/sdcard/Pictures/AirSend".to_string()
        } else {
            self.download_dir.clone()
        };

        tokio::fs::create_dir_all(&actual_dir).await?;

        let mut final_file_name = file_name.to_string();
        let mut file_path = format!("{}/{}", actual_dir, final_file_name);
        let mut counter = 1;
        while Path::new(&file_path).exists() {
            let path = Path::new(file_name);
            let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or(file_name);
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
            final_file_name = if ext.is_empty() {
                format!("{} ({})", stem, counter)
            } else {
                format!("{} ({}).{}", stem, counter, ext)
            };
            file_path = format!("{}/{}", actual_dir, final_file_name);
            counter += 1;
        }

        tokio::fs::write(&file_path, bytes).await?;

        if file_type.starts_with("image/") || file_type.starts_with("video/") {
            let _ = std::process::Command::new("am")
                .args([
                    "broadcast",
                    "-a",
                    "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                    "-d",
                    &format!("file://{}", file_path),
                ])
                .spawn();
        }

        Ok(())
    }
}
