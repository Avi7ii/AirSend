use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::path::Path;
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::time::{sleep, Instant};
use uuid::Uuid;

use crate::Client;

const CAMPUS_MARKER: u8 = 1;
const CHUNK_SIZE: usize = 600;
const WINDOW_SIZE: usize = 24;
pub const MAX_FALLBACK_BYTES: usize = 1 * 1024 * 1024;
const STALE_TRANSFER_TIMEOUT: Duration = Duration::from_secs(90);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CampusEnvelope {
    campus_fallback: u8,
    #[serde(rename = "type")]
    kind: String,
    transfer_id: String,
    session_nonce: String,
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
    fn base(
        kind: &str,
        transfer_id: String,
        session_nonce: String,
        sender_id: String,
        target_id: String,
    ) -> Self {
        Self {
            campus_fallback: CAMPUS_MARKER,
            kind: kind.to_string(),
            transfer_id,
            session_nonce,
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

#[derive(Debug, Clone)]
struct OutgoingTransferState {
    session_nonce: String,
    accepted: bool,
    source_ip: Option<String>,
    window_results: HashMap<usize, OutgoingWindowResult>,
    completion: Option<Result<(), String>>,
    cancelled: bool,
    last_activity_at: Instant,
}

impl OutgoingTransferState {
    fn new(session_nonce: String) -> Self {
        Self {
            session_nonce,
            accepted: false,
            source_ip: None,
            window_results: HashMap::new(),
            completion: None,
            cancelled: false,
            last_activity_at: Instant::now(),
        }
    }
}

#[derive(Debug, Clone)]
struct IncomingTransferState {
    sender_id: String,
    sender_alias: String,
    session_nonce: String,
    source_ip: String,
    file_name: String,
    file_type: String,
    total_size: usize,
    total_chunks: usize,
    next_window_start: usize,
    assembled: Vec<u8>,
    window_chunks: HashMap<usize, Vec<u8>>,
    last_activity_at: Instant,
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
        self.send_campus_payload(peer_id, file_name, file_type, bytes)
            .await
    }

    pub async fn maybe_handle_campus_message(&self, message: &str, source: SocketAddr) -> bool {
        self.prune_campus_state().await;

        let Ok(envelope) = serde_json::from_str::<CampusEnvelope>(message) else {
            return false;
        };
        if envelope.campus_fallback != CAMPUS_MARKER {
            return false;
        }
        let source_ip = source.ip().to_string();

        tracing::debug!(
            "Campus packet rx type={} transfer={} from={} to={} via={}",
            envelope.kind,
            envelope.transfer_id,
            envelope.sender_id,
            envelope.target_id,
            source_ip
        );
        match self.handle_campus_message(envelope, &source_ip).await {
            Ok(()) => {}
            Err(err) => tracing::warn!("Campus fallback error: {}", err),
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
        self.prune_campus_state().await;

        if bytes.is_empty() {
            return Ok(());
        }
        if bytes.len() > MAX_FALLBACK_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!(
                    "Campus fallback only supports files up to {} bytes",
                    MAX_FALLBACK_BYTES
                ),
            )
            .into());
        }

        let transfer_id = Uuid::new_v4().to_string();
        let session_nonce = Uuid::new_v4().simple().to_string();
        let total_chunks = bytes.len().div_ceil(CHUNK_SIZE);

        {
            let mut campus = self.campus_fallback.lock().await;
            campus.outgoing.insert(
                transfer_id.clone(),
                OutgoingTransferState::new(session_nonce.clone()),
            );
        }

        let result = async {
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
                    session_nonce.clone(),
                    self.device.fingerprint.clone(),
                    peer_id.to_string(),
                )
            };

            let accepted = self.await_prepare_accept(&transfer_id, &prepare).await?;
            if !accepted {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "Campus fallback accept timed out",
                )
                .into());
            }

            for window_start in (0..total_chunks).step_by(WINDOW_SIZE) {
                self.ensure_campus_outgoing_active(&transfer_id).await?;

                let window_end = usize::min(window_start + WINDOW_SIZE, total_chunks);
                let mut pending: Vec<usize> = (window_start..window_end).collect();
                let mut attempts = 0;

                while !pending.is_empty() {
                    self.ensure_campus_outgoing_active(&transfer_id).await?;

                    attempts += 1;
                    if attempts > 6 {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            format!("Campus fallback window {} failed", window_start),
                        )
                        .into());
                    }

                    for &chunk_index in &pending {
                        self.ensure_campus_outgoing_active(&transfer_id).await?;

                        let start = chunk_index * CHUNK_SIZE;
                        let end = usize::min(start + CHUNK_SIZE, bytes.len());
                        let mut chunk = CampusEnvelope::base(
                            "chunk",
                            transfer_id.clone(),
                            session_nonce.clone(),
                            self.device.fingerprint.clone(),
                            peer_id.to_string(),
                        );
                        chunk.window_start = Some(window_start);
                        chunk.index = Some(chunk_index);
                        chunk.payload = Some(BASE64.encode(&bytes[start..end]));
                        self.touch_campus_outgoing(&transfer_id).await;
                        self.send_campus_message(&chunk).await?;
                        sleep(Duration::from_millis(2)).await;
                    }

                    let mut window_end_msg = CampusEnvelope::base(
                        "windowEnd",
                        transfer_id.clone(),
                        session_nonce.clone(),
                        self.device.fingerprint.clone(),
                        peer_id.to_string(),
                    );
                    window_end_msg.window_start = Some(window_start);
                    window_end_msg.count = Some(window_end - window_start);
                    self.touch_campus_outgoing(&transfer_id).await;
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

            self.ensure_campus_outgoing_active(&transfer_id).await?;
            let finish = CampusEnvelope::base(
                "finish",
                transfer_id.clone(),
                session_nonce.clone(),
                self.device.fingerprint.clone(),
                peer_id.to_string(),
            );
            self.touch_campus_outgoing(&transfer_id).await;
            self.send_campus_message(&finish).await?;
            self.await_completion(&transfer_id).await?;
            Ok(())
        }
        .await;

        self.cleanup_campus_outgoing(&transfer_id).await;
        result
    }

    async fn handle_campus_message(
        &self,
        envelope: CampusEnvelope,
        source_ip: &str,
    ) -> crate::error::Result<()> {
        match envelope.kind.as_str() {
            "prepare" => self.handle_campus_prepare(envelope, source_ip).await,
            "chunk" => self.handle_campus_chunk(envelope, source_ip).await,
            "windowEnd" => self.handle_campus_window_end(envelope, source_ip).await,
            "finish" => self.handle_campus_finish(envelope, source_ip).await,
            "accept" | "windowAck" | "windowNack" | "complete" => {
                self.handle_campus_outgoing_event(envelope, source_ip).await;
                Ok(())
            }
            _ => Ok(()),
        }
    }

    async fn handle_campus_prepare(
        &self,
        envelope: CampusEnvelope,
        source_ip: &str,
    ) -> crate::error::Result<()> {
        if envelope.target_id != self.device.fingerprint {
            return Ok(());
        }
        let file_name = envelope
            .file_name
            .unwrap_or_else(|| "CampusTransfer.bin".to_string());
        let file_type = envelope
            .file_type
            .unwrap_or_else(|| "application/octet-stream".to_string());
        let total_size = envelope.total_size.unwrap_or(0);
        let total_chunks = envelope.total_chunks.unwrap_or(0);
        let _window_size = envelope.window_size.unwrap_or(WINDOW_SIZE);
        if total_size == 0 || total_size > MAX_FALLBACK_BYTES || total_chunks == 0 {
            return Ok(());
        }

        {
            let mut campus = self.campus_fallback.lock().await;
            if let Some(existing) = campus.incoming.get_mut(&envelope.transfer_id) {
                if existing.source_ip == source_ip
                    && existing.session_nonce == envelope.session_nonce
                    && existing.sender_id == envelope.sender_id
                {
                    existing.last_activity_at = Instant::now();
                    let accept = CampusEnvelope::base(
                        "accept",
                        envelope.transfer_id,
                        envelope.session_nonce,
                        self.device.fingerprint.clone(),
                        envelope.sender_id,
                    );
                    drop(campus);
                    return self.send_campus_message_repeated(&accept, 3).await;
                }
            }
        }

        let state = IncomingTransferState {
            sender_id: envelope.sender_id.clone(),
            sender_alias: envelope
                .sender_alias
                .unwrap_or_else(|| "Campus Sender".to_string()),
            session_nonce: envelope.session_nonce.clone(),
            source_ip: source_ip.to_string(),
            file_name,
            file_type,
            total_size,
            total_chunks,
            next_window_start: 0,
            assembled: Vec::with_capacity(total_size),
            window_chunks: HashMap::new(),
            last_activity_at: Instant::now(),
        };

        {
            let mut campus = self.campus_fallback.lock().await;
            campus.incoming.insert(envelope.transfer_id.clone(), state);
        }

        let accept = CampusEnvelope::base(
            "accept",
            envelope.transfer_id,
            envelope.session_nonce,
            self.device.fingerprint.clone(),
            envelope.sender_id,
        );
        self.send_campus_message_repeated(&accept, 3).await
    }

    async fn handle_campus_chunk(
        &self,
        envelope: CampusEnvelope,
        source_ip: &str,
    ) -> crate::error::Result<()> {
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
            if state.source_ip != source_ip || state.session_nonce != envelope.session_nonce {
                return Ok(());
            }
            if index >= state.total_chunks {
                return Ok(());
            }
            state.window_chunks.entry(index).or_insert(decoded);
            state.last_activity_at = Instant::now();
        }
        Ok(())
    }

    async fn handle_campus_window_end(
        &self,
        envelope: CampusEnvelope,
        source_ip: &str,
    ) -> crate::error::Result<()> {
        if envelope.target_id != self.device.fingerprint {
            return Ok(());
        }
        let window_start = envelope.window_start.unwrap_or(0);
        let count = envelope.count.unwrap_or(0);
        let mut missing = Vec::new();

        let ack_target = {
            let mut campus = self.campus_fallback.lock().await;
            let Some(state) = campus.incoming.get_mut(&envelope.transfer_id) else {
                return Ok(());
            };
            if state.source_ip != source_ip || state.session_nonce != envelope.session_nonce {
                return Ok(());
            }
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

            state.last_activity_at = Instant::now();
            Some(state.sender_id.clone())
        };

        let Some(target_id) = ack_target else {
            return Ok(());
        };

        let mut response = CampusEnvelope::base(
            if missing.is_empty() {
                "windowAck"
            } else {
                "windowNack"
            },
            envelope.transfer_id,
            envelope.session_nonce,
            self.device.fingerprint.clone(),
            target_id,
        );
        response.window_start = Some(window_start);
        if !missing.is_empty() {
            response.missing = Some(missing);
        }
        self.send_campus_message_repeated(&response, 3).await
    }

    async fn handle_campus_finish(
        &self,
        envelope: CampusEnvelope,
        source_ip: &str,
    ) -> crate::error::Result<()> {
        if envelope.target_id != self.device.fingerprint {
            return Ok(());
        }

        let state = {
            let mut campus = self.campus_fallback.lock().await;
            let Some(current_state) = campus.incoming.get(&envelope.transfer_id) else {
                return Ok(());
            };
            if current_state.source_ip != source_ip
                || current_state.session_nonce != envelope.session_nonce
            {
                return Ok(());
            }
            campus.incoming.remove(&envelope.transfer_id)
        };

        let Some(state) = state else {
            return Ok(());
        };

        let outcome = if state.assembled.len() == state.total_size
            && state.next_window_start == state.total_chunks
        {
            Ok(state.clone())
        } else {
            Err(format!(
                "Incomplete campus transfer from {}: got {} / {} bytes",
                state.sender_alias,
                state.assembled.len(),
                state.total_size
            ))
        };

        let mut complete = CampusEnvelope::base(
            "complete",
            envelope.transfer_id,
            state.session_nonce.clone(),
            self.device.fingerprint.clone(),
            envelope.sender_id,
        );

        match outcome {
            Ok(state) => {
                if let Err(err) = self
                    .persist_campus_bytes(&state.file_name, &state.file_type, &state.assembled)
                    .await
                {
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

        self.send_campus_message_repeated(&complete, 3).await
    }

    async fn handle_campus_outgoing_event(&self, envelope: CampusEnvelope, source_ip: &str) {
        if envelope.target_id != self.device.fingerprint {
            return;
        }

        let mut campus = self.campus_fallback.lock().await;
        let Some(state) = campus.outgoing.get_mut(&envelope.transfer_id) else {
            return;
        };
        if state.session_nonce != envelope.session_nonce {
            return;
        }
        if let Some(bound_source_ip) = state.source_ip.as_deref() {
            if bound_source_ip != source_ip {
                return;
            }
        } else if envelope.kind == "accept" {
            state.source_ip = Some(source_ip.to_string());
        } else {
            return;
        }

        match envelope.kind.as_str() {
            "accept" => state.accepted = true,
            "windowAck" => {
                if let Some(window_start) = envelope.window_start {
                    state
                        .window_results
                        .insert(window_start, OutgoingWindowResult::Ack);
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
                    Err(envelope
                        .message
                        .unwrap_or_else(|| "Campus transfer failed".to_string()))
                };
                state.completion = Some(result);
            }
            _ => {}
        }
        state.last_activity_at = Instant::now();
    }

    async fn send_campus_message(&self, message: &CampusEnvelope) -> crate::error::Result<()> {
        let payload = serde_json::to_vec(message)?;
        tracing::debug!(
            "Campus packet tx type={} transfer={} from={} to={}",
            message.kind,
            message.transfer_id,
            message.sender_id,
            message.target_id
        );
        let broadcast_addr =
            SocketAddrV4::new(Ipv4Addr::new(255, 255, 255, 255), self.discovery_port);

        let multicast_result = self.socket.send_to(&payload, self.multicast_addr).await;
        let broadcast_result = self.socket.send_to(&payload, broadcast_addr).await;

        match (multicast_result, broadcast_result) {
            (Ok(_), _) | (_, Ok(_)) => Ok(()),
            (Err(multicast_err), Err(broadcast_err)) => Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!(
                    "Campus multicast send failed: {}; broadcast send failed: {}",
                    multicast_err, broadcast_err
                ),
            )
            .into()),
        }
    }

    async fn send_campus_message_repeated(
        &self,
        message: &CampusEnvelope,
        attempts: usize,
    ) -> crate::error::Result<()> {
        for attempt in 0..attempts {
            self.send_campus_message(message).await?;
            if attempt + 1 < attempts {
                sleep(Duration::from_millis(120)).await;
            }
        }
        Ok(())
    }

    async fn await_prepare_accept(
        &self,
        transfer_id: &str,
        prepare: &CampusEnvelope,
    ) -> crate::error::Result<bool> {
        for _ in 0..6 {
            self.ensure_campus_outgoing_active(transfer_id).await?;
            self.touch_campus_outgoing(transfer_id).await;
            self.send_campus_message(prepare).await?;
            let started = Instant::now();
            while started.elapsed() < Duration::from_millis(1500) {
                self.prune_campus_state().await;
                self.ensure_campus_outgoing_active(transfer_id).await?;
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
        while started.elapsed() < Duration::from_millis(3500) {
            self.prune_campus_state().await;
            self.ensure_campus_outgoing_active(transfer_id).await?;
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
            self.prune_campus_state().await;
            self.ensure_campus_outgoing_active(transfer_id).await?;
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

    async fn ensure_campus_outgoing_active(&self, transfer_id: &str) -> crate::error::Result<()> {
        let mut campus = self.campus_fallback.lock().await;
        let Some(state) = campus.outgoing.get(transfer_id) else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Campus fallback state expired",
            )
            .into());
        };
        if state.cancelled {
            campus.outgoing.remove(transfer_id);
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Campus transfer cancelled",
            )
            .into());
        }
        Ok(())
    }

    async fn touch_campus_outgoing(&self, transfer_id: &str) {
        let mut campus = self.campus_fallback.lock().await;
        if let Some(state) = campus.outgoing.get_mut(transfer_id) {
            state.last_activity_at = Instant::now();
        }
    }

    async fn prune_campus_state(&self) {
        let now = Instant::now();
        let mut campus = self.campus_fallback.lock().await;
        let incoming_before = campus.incoming.len();
        let outgoing_before = campus.outgoing.len();
        campus.incoming.retain(|_, state| {
            now.duration_since(state.last_activity_at) <= STALE_TRANSFER_TIMEOUT
        });
        campus.outgoing.retain(|_, state| {
            now.duration_since(state.last_activity_at) <= STALE_TRANSFER_TIMEOUT
        });
        let incoming_pruned = incoming_before.saturating_sub(campus.incoming.len());
        let outgoing_pruned = outgoing_before.saturating_sub(campus.outgoing.len());
        if incoming_pruned > 0 || outgoing_pruned > 0 {
            tracing::info!(
                "Campus fallback pruned stale transfers incoming={} outgoing={}",
                incoming_pruned,
                outgoing_pruned
            );
        }
    }

    async fn persist_campus_bytes(
        &self,
        file_name: &str,
        file_type: &str,
        bytes: &[u8],
    ) -> crate::error::Result<()> {
        if file_type == "text/plain" && file_name == "clipboard.txt" {
            let mut stream = UnixStream::connect("\0airsend_app_ipc")
                .await
                .map_err(|err| {
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
            let stem = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(file_name);
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
