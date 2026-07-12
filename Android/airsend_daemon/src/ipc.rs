use crate::config::{AirSendConfig, ConfigStore, CONFIG_VERSION};
use crate::domain::{TransferSource, TransferStatus};
use crate::events::EventHub;
use crate::history::{HistoryStore, SCHEMA_VERSION};
use crate::logging::SizeRotatingWriter;
use crate::protocol::{
    LegacyCommand, ParsedLine, RequestEnvelope, ResponseEnvelope, IPC_PROTOCOL_VERSION,
};
use crate::transfers::{
    OutgoingItemSpec, OutgoingPayload, OutgoingTransferSpec, TransferExecution, TransferService,
};
use crate::{process_command, AppState};
use anyhow::{anyhow, Context, Result};
use futures_util::StreamExt;
use localsend::models::file::FileMetadata;
use reqwest::Body;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{watch, RwLock};
use tokio::task::JoinHandle;
use tokio_util::io::ReaderStream;

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const DEFAULT_LOG_TAIL_BYTES: usize = 64 * 1024;
const MAX_LOG_TAIL_BYTES: usize = 256 * 1024;
const EVENT_CAPACITY: usize = 128;

const CAPABILITIES: &[&str] = &[
    "hello",
    "subscribe",
    "get_state",
    "get_peers",
    "get_config",
    "set_config",
    "get_history",
    "delete_history",
    "clear_history",
    "get_logs",
    "clear_logs",
    "send_text",
    "send_file",
    "send_files",
    "get_transfers",
    "cancel_transfer",
    "retry_transfer",
];

pub struct DaemonServices {
    config_store: ConfigStore,
    config: RwLock<AirSendConfig>,
    history: Arc<HistoryStore>,
    events: EventHub,
    transfers: TransferService,
    health_warnings: RwLock<Vec<String>>,
    log_writer: SizeRotatingWriter,
    tls_fingerprint: String,
    transport_protocol: String,
    started_at_ms: u64,
}

impl DaemonServices {
    pub fn new(
        config_store: ConfigStore,
        config: AirSendConfig,
        history: Arc<HistoryStore>,
        log_writer: SizeRotatingWriter,
        health_warnings: Vec<String>,
        tls_fingerprint: String,
        transport_protocol: impl Into<String>,
    ) -> Self {
        let events = EventHub::new(EVENT_CAPACITY);
        let transfers = TransferService::new(history.clone(), events.clone(), 100);
        Self {
            config_store,
            config: RwLock::new(config),
            history,
            events,
            transfers,
            health_warnings: RwLock::new(health_warnings),
            log_writer,
            tls_fingerprint,
            transport_protocol: transport_protocol.into(),
            started_at_ms: now_ms(),
        }
    }

    pub async fn config(&self) -> AirSendConfig {
        self.config.read().await.clone()
    }

    pub fn events(&self) -> &EventHub {
        &self.events
    }

    async fn state_snapshot(&self, peer_count: usize) -> Result<Value> {
        let config = self.config().await;
        let history_count = self.history.list(usize::MAX)?.len();
        let active_transfer_count = self
            .transfers
            .list()
            .await
            .into_iter()
            .filter(|transfer| !transfer.status.is_terminal())
            .count();
        let warnings = self.health_warnings.read().await.clone();
        Ok(json!({
            "protocolVersion": IPC_PROTOCOL_VERSION,
            "daemonVersion": env!("CARGO_PKG_VERSION"),
            "configVersion": CONFIG_VERSION,
            "historySchemaVersion": SCHEMA_VERSION,
            "startedAtMs": self.started_at_ms,
            "peerCount": peer_count,
            "preferredTarget": config.preferred_target,
            "historyCount": history_count,
            "activeTransferCount": active_transfer_count,
            "healthWarnings": warnings,
            "tlsFingerprint": self.tls_fingerprint,
            "transportProtocol": self.transport_protocol,
        }))
    }

    async fn set_config(&self, config: AirSendConfig) -> Result<AirSendConfig> {
        let normalized = config.normalized()?;
        self.config_store.save(&normalized)?;
        *self.config.write().await = normalized.clone();
        self.events.publish(
            "config_changed",
            serde_json::to_value(&normalized).context("failed to encode config event")?,
        );
        Ok(normalized)
    }
}

pub async fn handle_client(stream: UnixStream, state: Arc<AppState>) -> Result<()> {
    let (reader, writer) = stream.into_split();
    let writer = Arc::new(tokio::sync::Mutex::new(writer));
    let mut reader = BufReader::new(reader);
    let mut line = Vec::new();
    let mut event_forwarder: Option<JoinHandle<()>> = None;

    loop {
        line.clear();
        let bytes_read = reader.read_until(b'\n', &mut line).await?;
        if bytes_read == 0 {
            break;
        }
        if line.len() > MAX_REQUEST_BYTES {
            tracing::warn!("Rejected oversized IPC request: {} bytes", line.len());
            break;
        }
        trim_line_ending(&mut line);
        if line.is_empty() {
            continue;
        }
        let raw = match std::str::from_utf8(&line) {
            Ok(raw) => raw,
            Err(error) => {
                tracing::warn!("Rejected non-UTF-8 IPC request: {error}");
                continue;
            }
        };

        match ParsedLine::parse(raw) {
            Ok(ParsedLine::Request(request)) => {
                let subscribe = request.op == "subscribe";
                let response = dispatch_request(request, &state).await;
                write_json_line(&writer, &response).await?;
                if subscribe && response.ok && event_forwarder.is_none() {
                    event_forwarder = Some(spawn_event_forwarder(
                        state.services.events().subscribe(),
                        writer.clone(),
                    ));
                }
            }
            Ok(ParsedLine::Legacy(LegacyCommand::GetPeers)) => {
                let peers = peer_snapshot(&state).await;
                write_json_line(&writer, &peers).await?;
            }
            Ok(ParsedLine::Legacy(command)) => {
                let state = state.clone();
                tokio::spawn(async move {
                    if let Err(error) = process_command(command, &state).await {
                        tracing::error!("Legacy IPC command failed: {error:#}");
                    }
                });
            }
            Err(error) => tracing::warn!("Invalid IPC command: {error:#}"),
        }
    }

    if let Some(forwarder) = event_forwarder {
        forwarder.abort();
    }
    Ok(())
}

async fn dispatch_request(request: RequestEnvelope, state: &Arc<AppState>) -> ResponseEnvelope {
    let id = request.id.clone();
    match request.op.as_str() {
        "get_peers" => ResponseEnvelope::success(id, peer_snapshot(state).await),
        "send_text" => {
            let payload = match serde_json::from_value::<SendTextPayload>(request.payload) {
                Ok(payload) if !payload.text.is_empty() => payload,
                Ok(_) => return invalid_payload(id, "text must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let item = OutgoingItemSpec {
                id: uuid::Uuid::new_v4().to_string(),
                name: "clipboard.txt".to_string(),
                mime_type: "text/plain".to_string(),
                size: payload.text.len() as u64,
                payload: OutgoingPayload::Text(payload.text),
            };
            queue_outgoing_response(
                id,
                state,
                payload.target_id,
                TransferSource::Clipboard,
                vec![item],
            )
            .await
        }
        "send_file" => {
            let payload = match serde_json::from_value::<SendFilePayload>(request.payload) {
                Ok(payload) if !payload.path.is_empty() => payload,
                Ok(_) => return invalid_payload(id, "path must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            queue_paths_response(id, state, payload.target_id, vec![payload.path]).await
        }
        "send_files" => {
            let payload = match serde_json::from_value::<SendFilesPayload>(request.payload) {
                Ok(payload) if !payload.paths.is_empty() => payload,
                Ok(_) => return invalid_payload(id, "paths must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            queue_paths_response(id, state, payload.target_id, payload.paths).await
        }
        "cancel_transfer" => {
            let payload = match serde_json::from_value::<TransferIdPayload>(request.payload) {
                Ok(payload) if !payload.id.trim().is_empty() => payload,
                Ok(_) => return invalid_payload(id, "id must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let Some(record) = state.services.transfers.get(&payload.id).await else {
                return ResponseEnvelope::error(id, "transfer_not_found", "Transfer not found");
            };
            if record.status.is_terminal() {
                return ResponseEnvelope::success(id, json!({"cancelRequested": false}));
            }
            match state.services.transfers.request_cancel(&payload.id).await {
                Ok(cancelled) => {
                    ResponseEnvelope::success(id, json!({"cancelRequested": cancelled}))
                }
                Err(error) => transfer_error(id, error.to_string()),
            }
        }
        "retry_transfer" => {
            let payload = match serde_json::from_value::<TransferIdPayload>(request.payload) {
                Ok(payload) if !payload.id.trim().is_empty() => payload,
                Ok(_) => return invalid_payload(id, "id must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let Some(record) = state.services.transfers.get(&payload.id).await else {
                return ResponseEnvelope::error(id, "transfer_not_found", "Transfer not found");
            };
            if !record.retryable {
                return ResponseEnvelope::error(
                    id,
                    "transfer_not_retryable",
                    "Transfer cannot be retried",
                );
            }
            let Some(spec) = state.services.transfers.retry_spec(&payload.id).await else {
                return ResponseEnvelope::error(
                    id,
                    "transfer_not_retryable",
                    "Transfer payload is no longer available",
                );
            };
            queue_spec_response(id, state, spec).await
        }
        _ => {
            let peer_count = state.client.peers.lock().await.len();
            dispatch_service_request(request, &state.services, peer_count).await
        }
    }
}

async fn queue_paths_response(
    id: String,
    state: &Arc<AppState>,
    target_id: Option<String>,
    paths: Vec<String>,
) -> ResponseEnvelope {
    let mut items = Vec::with_capacity(paths.len());
    for raw_path in paths {
        let path = PathBuf::from(&raw_path);
        let metadata = match tokio::fs::metadata(&path).await {
            Ok(metadata) if metadata.is_file() => metadata,
            Ok(_) => return invalid_payload(id, &format!("path is not a file: {raw_path}")),
            Err(error) => return transfer_error(id, format!("{raw_path}: {error}")),
        };
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("file")
            .to_string();
        items.push(OutgoingItemSpec {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            mime_type: crate::infer_campus_mime_type(&path),
            size: metadata.len(),
            payload: OutgoingPayload::File(path),
        });
    }
    queue_outgoing_response(id, state, target_id, TransferSource::AppPicker, items).await
}

async fn queue_outgoing_response(
    id: String,
    state: &Arc<AppState>,
    target_id: Option<String>,
    source: TransferSource,
    items: Vec<OutgoingItemSpec>,
) -> ResponseEnvelope {
    let target_id = match target_id {
        Some(target_id) => Some(target_id),
        None => state.services.config().await.preferred_target,
    }
    .filter(|value| !value.trim().is_empty());
    let Some(target_id) = target_id else {
        return ResponseEnvelope::error(id, "no_target", "Select a target before sending");
    };
    let (peer_alias, peer_fingerprint) = {
        let peers = state.client.peers.lock().await;
        peers
            .get(&target_id)
            .map(|(_, peer)| (peer.alias.clone(), Some(peer.fingerprint.clone())))
            .unwrap_or_else(|| (target_id.clone(), None))
    };
    queue_spec_response(
        id,
        state,
        OutgoingTransferSpec {
            target_id,
            peer_alias,
            peer_fingerprint,
            source,
            items,
        },
    )
    .await
}

async fn queue_spec_response(
    id: String,
    state: &Arc<AppState>,
    spec: OutgoingTransferSpec,
) -> ResponseEnvelope {
    match state.services.transfers.register_outgoing(spec).await {
        Ok(execution) => {
            let record = state.services.transfers.get(&execution.transfer_id).await;
            let task_state = state.clone();
            tokio::spawn(async move {
                run_outgoing_transfer(task_state, execution).await;
            });
            match record {
                Some(record) => ResponseEnvelope::success(
                    id,
                    serde_json::to_value(record).unwrap_or(Value::Null),
                ),
                None => ResponseEnvelope::error(
                    id,
                    "transfer_failed",
                    "Transfer session was not created",
                ),
            }
        }
        Err(error) => transfer_error(id, error.to_string()),
    }
}

async fn run_outgoing_transfer(state: Arc<AppState>, execution: TransferExecution) {
    let transfer_id = execution.transfer_id.clone();
    match execute_outgoing_transfer(&state, execution).await {
        Ok(OutgoingOutcome::Completed) => {
            if let Err(error) = state
                .services
                .transfers
                .finish_completed(&transfer_id)
                .await
            {
                tracing::error!("Failed to complete transfer {transfer_id}: {error:#}");
            }
        }
        Ok(OutgoingOutcome::Cancelled) => {
            if let Err(error) = state
                .services
                .transfers
                .finish_cancelled(&transfer_id)
                .await
            {
                tracing::error!("Failed to cancel transfer {transfer_id}: {error:#}");
            }
        }
        Err(error) => {
            let message = error.to_string();
            let code = transfer_error_code(&message);
            let retryable = code != "file_not_found";
            if let Err(finish_error) = state
                .services
                .transfers
                .finish_failed(&transfer_id, code, &message, retryable)
                .await
            {
                tracing::error!(
                    "Failed to record transfer {transfer_id} failure: {finish_error:#}"
                );
            }
        }
    }
}

enum OutgoingOutcome {
    Completed,
    Cancelled,
}

async fn execute_outgoing_transfer(
    state: &AppState,
    mut execution: TransferExecution,
) -> Result<OutgoingOutcome> {
    let transfer_id = execution.transfer_id.clone();
    state
        .services
        .transfers
        .transition(&transfer_id, TransferStatus::Preparing)
        .await?;

    let files = execution
        .spec
        .items
        .iter()
        .map(|item| {
            (
                item.id.clone(),
                FileMetadata {
                    id: item.id.clone(),
                    file_name: item.name.clone(),
                    size: item.size,
                    file_type: item.mime_type.clone(),
                    sha256: None,
                    preview: None,
                    metadata: None,
                },
            )
        })
        .collect::<HashMap<_, _>>();

    let prepare_result = tokio::select! {
        biased;
        _ = wait_for_cancel(&mut execution.cancel) => return Ok(OutgoingOutcome::Cancelled),
        result = state.client.prepare_upload(execution.spec.target_id.clone(), files) => result,
    };
    let prepare = match prepare_result {
        Ok(prepare) => prepare,
        Err(direct_error) => {
            tracing::warn!(
                "Direct prepare failed for transfer {transfer_id}; trying campus fallback: {direct_error}"
            );
            return execute_campus_fallback(state, &mut execution)
                .await
                .with_context(|| format!("direct transfer failed: {direct_error}"));
        }
    };

    state
        .services
        .transfers
        .transition(&transfer_id, TransferStatus::Transferring)
        .await?;

    for item in &execution.spec.items {
        if *execution.cancel.borrow() {
            let _ = state.client.cancel_upload(prepare.session_id.clone()).await;
            return Ok(OutgoingOutcome::Cancelled);
        }
        let token = prepare
            .files
            .get(&item.id)
            .cloned()
            .ok_or_else(|| anyhow!("receiver did not return a token for {}", item.name))?;
        let body = outgoing_body(&state.services.transfers, &transfer_id, item).await?;
        let upload = tokio::select! {
            biased;
            _ = wait_for_cancel(&mut execution.cancel) => {
                let _ = state.client.cancel_upload(prepare.session_id.clone()).await;
                return Ok(OutgoingOutcome::Cancelled);
            }
            result = state.client.upload(
                prepare.session_id.clone(),
                item.id.clone(),
                token,
                body,
            ) => result,
        };
        upload.with_context(|| format!("failed to upload {}", item.name))?;
        state
            .services
            .transfers
            .set_file_progress(&transfer_id, &item.id, item.size)
            .await?;
    }

    Ok(OutgoingOutcome::Completed)
}

async fn outgoing_body(
    transfers: &TransferService,
    transfer_id: &str,
    item: &OutgoingItemSpec,
) -> Result<Body> {
    match &item.payload {
        OutgoingPayload::Text(text) => Ok(Body::from(text.clone())),
        OutgoingPayload::File(path) => {
            let file = tokio::fs::File::open(path)
                .await
                .with_context(|| format!("failed to open {}", path.display()))?;
            let service = transfers.clone();
            let transfer_id = transfer_id.to_string();
            let file_id = item.id.clone();
            let transferred = Arc::new(AtomicU64::new(0));
            let stream = ReaderStream::new(file).then(move |chunk| {
                let service = service.clone();
                let transfer_id = transfer_id.clone();
                let file_id = file_id.clone();
                let transferred = transferred.clone();
                async move {
                    let bytes = chunk?;
                    let current = transferred.fetch_add(bytes.len() as u64, Ordering::Relaxed)
                        + bytes.len() as u64;
                    service
                        .set_file_progress(&transfer_id, &file_id, current)
                        .await
                        .map_err(io::Error::other)?;
                    Ok::<_, io::Error>(bytes)
                }
            });
            Ok(Body::wrap_stream(stream))
        }
    }
}

async fn execute_campus_fallback(
    state: &AppState,
    execution: &mut TransferExecution,
) -> Result<OutgoingOutcome> {
    state
        .services
        .transfers
        .transition(&execution.transfer_id, TransferStatus::Transferring)
        .await?;
    for item in &execution.spec.items {
        let send = async {
            match &item.payload {
                OutgoingPayload::Text(text) => state
                    .client
                    .send_campus_text(&execution.spec.target_id, text)
                    .await
                    .map_err(anyhow::Error::from),
                OutgoingPayload::File(path) => {
                    if item.size > crate::MAX_FALLBACK_BYTES as u64 {
                        return Err(anyhow!(
                            "campus fallback only supports files up to {} bytes",
                            crate::MAX_FALLBACK_BYTES
                        ));
                    }
                    let bytes = tokio::fs::read(path)
                        .await
                        .with_context(|| format!("failed to read {}", path.display()))?;
                    state
                        .client
                        .send_campus_file(
                            &execution.spec.target_id,
                            &item.name,
                            &item.mime_type,
                            &bytes,
                        )
                        .await
                        .map_err(anyhow::Error::from)
                }
            }
        };
        tokio::select! {
            biased;
            _ = wait_for_cancel(&mut execution.cancel) => return Ok(OutgoingOutcome::Cancelled),
            result = send => result?,
        }
        state
            .services
            .transfers
            .set_file_progress(&execution.transfer_id, &item.id, item.size)
            .await?;
    }
    Ok(OutgoingOutcome::Completed)
}

async fn wait_for_cancel(receiver: &mut watch::Receiver<bool>) {
    if *receiver.borrow() {
        return;
    }
    while receiver.changed().await.is_ok() {
        if *receiver.borrow() {
            return;
        }
    }
}

async fn dispatch_service_request(
    request: RequestEnvelope,
    services: &DaemonServices,
    peer_count: usize,
) -> ResponseEnvelope {
    let id = request.id;
    if !matches!(
        request.op.as_str(),
        "hello"
            | "subscribe"
            | "get_state"
            | "get_config"
            | "set_config"
            | "get_history"
            | "delete_history"
            | "clear_history"
            | "get_logs"
            | "clear_logs"
            | "get_transfers"
    ) {
        return ResponseEnvelope::error(
            id,
            "unknown_operation",
            format!("Unknown IPC operation: {}", request.op),
        );
    }
    let result: Result<Value> = async {
        match request.op.as_str() {
            "hello" => Ok(json!({
                "protocolVersion": IPC_PROTOCOL_VERSION,
                "daemonVersion": env!("CARGO_PKG_VERSION"),
                "configVersion": CONFIG_VERSION,
                "historySchemaVersion": SCHEMA_VERSION,
                "capabilities": CAPABILITIES,
                "transportProtocol": services.transport_protocol,
            })),
            "subscribe" => Ok(json!({"subscribed": true})),
            "get_state" => services.state_snapshot(peer_count).await,
            "get_config" => Ok(serde_json::to_value(services.config().await)?),
            "set_config" => {
                let config = serde_json::from_value::<AirSendConfig>(request.payload)
                    .context("invalid config payload")?;
                Ok(serde_json::to_value(services.set_config(config).await?)?)
            }
            "get_history" => {
                let payload = serde_json::from_value::<HistoryListPayload>(request.payload)
                    .context("invalid history payload")?;
                Ok(serde_json::to_value(
                    services
                        .history
                        .list(payload.limit.unwrap_or(100).min(500))?,
                )?)
            }
            "get_transfers" => Ok(serde_json::to_value(services.transfers.list().await)?),
            "delete_history" => {
                let payload = serde_json::from_value::<HistoryIdPayload>(request.payload)
                    .context("invalid history id payload")?;
                let deleted = services.history.delete(&payload.id)?;
                if deleted {
                    services.events.publish(
                        "history_changed",
                        json!({"action": "delete", "id": payload.id}),
                    );
                }
                Ok(json!({"deleted": deleted}))
            }
            "clear_history" => {
                let deleted = services.history.clear()?;
                services.events.publish(
                    "history_changed",
                    json!({"action": "clear", "deleted": deleted}),
                );
                Ok(json!({"deleted": deleted}))
            }
            "get_logs" => {
                let payload = serde_json::from_value::<LogTailPayload>(request.payload)
                    .context("invalid log payload")?;
                let max_bytes = payload
                    .max_bytes
                    .unwrap_or(DEFAULT_LOG_TAIL_BYTES)
                    .min(MAX_LOG_TAIL_BYTES);
                let paths = services
                    .log_writer
                    .paths()?
                    .into_iter()
                    .filter_map(|path| {
                        let bytes = std::fs::metadata(&path).ok()?.len();
                        Some(json!({"path": path, "bytes": bytes}))
                    })
                    .collect::<Vec<_>>();
                Ok(json!({
                    "tail": services.log_writer.tail(max_bytes)?,
                    "files": paths,
                }))
            }
            "clear_logs" => {
                services.log_writer.clear()?;
                Ok(json!({"cleared": true}))
            }
            _ => unreachable!("service operation was validated before dispatch"),
        }
    }
    .await;

    match result {
        Ok(data) => ResponseEnvelope::success(id, data),
        Err(error) => ResponseEnvelope::error(id, "operation_failed", error.to_string()),
    }
}

async fn peer_snapshot(state: &AppState) -> Value {
    let preferred_target = state.services.config().await.preferred_target;
    let peers = state.client.peers.lock().await;
    Value::Array(
        peers
            .iter()
            .map(|(id, (address, info))| {
                json!({
                    "id": id,
                    "alias": info.alias,
                    "deviceModel": info.device_model,
                    "deviceType": info.device_type,
                    "version": info.version,
                    "fingerprint": info.fingerprint,
                    "address": address.to_string(),
                    "protocol": info.protocol,
                    "selected": preferred_target.as_deref() == Some(id.as_str()),
                    "manual": false,
                })
            })
            .collect(),
    )
}

fn spawn_event_forwarder(
    mut receiver: tokio::sync::broadcast::Receiver<crate::protocol::EventEnvelope>,
    writer: Arc<tokio::sync::Mutex<tokio::net::unix::OwnedWriteHalf>>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(event) => {
                    if write_json_line(&writer, &event).await.is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                    tracing::warn!("IPC event subscriber lagged by {skipped} events");
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    })
}

async fn write_json_line<T: serde::Serialize>(
    writer: &Arc<tokio::sync::Mutex<tokio::net::unix::OwnedWriteHalf>>,
    value: &T,
) -> Result<()> {
    let mut bytes = serde_json::to_vec(value)?;
    bytes.push(b'\n');
    writer.lock().await.write_all(&bytes).await?;
    Ok(())
}

fn trim_line_ending(line: &mut Vec<u8>) {
    if line.last() == Some(&b'\n') {
        line.pop();
    }
    if line.last() == Some(&b'\r') {
        line.pop();
    }
}

fn invalid_payload(id: String, message: &str) -> ResponseEnvelope {
    ResponseEnvelope::error(id, "invalid_payload", message)
}

fn transfer_error(id: String, message: String) -> ResponseEnvelope {
    let code = transfer_error_code(&message);
    ResponseEnvelope::error(id, code, message)
}

fn transfer_error_code(message: &str) -> &'static str {
    let lower = message.to_ascii_lowercase();
    if lower.contains("target not found")
        || lower.contains("peer not found")
        || lower.contains("no reachable target")
    {
        "target_offline"
    } else if lower.contains("no target") {
        "no_target"
    } else if lower.contains("no such file") || lower.contains("not found") {
        "file_not_found"
    } else {
        "transfer_failed"
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendTextPayload {
    #[serde(default)]
    target_id: Option<String>,
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendFilePayload {
    #[serde(default)]
    target_id: Option<String>,
    path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendFilesPayload {
    #[serde(default)]
    target_id: Option<String>,
    paths: Vec<String>,
}

#[derive(Deserialize)]
struct TransferIdPayload {
    id: String,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistoryListPayload {
    limit: Option<usize>,
}

#[derive(Deserialize)]
struct HistoryIdPayload {
    id: String,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LogTailPayload {
    max_bytes: Option<usize>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::IPC_PROTOCOL_VERSION;
    use serde_json::json;

    struct IpcHarness {
        services: Arc<DaemonServices>,
        _temp: tempfile::TempDir,
    }

    impl IpcHarness {
        async fn new() -> Self {
            let temp = tempfile::tempdir().unwrap();
            let config_store = ConfigStore::new(temp.path().join("config.json"));
            let config = AirSendConfig::default();
            config_store.save(&config).unwrap();
            let history = Arc::new(HistoryStore::open(temp.path().join("history.db"), 10).unwrap());
            let log_writer =
                SizeRotatingWriter::new(temp.path().join("airsend.log"), 1024, 2).unwrap();
            let services = Arc::new(DaemonServices::new(
                config_store,
                config,
                history,
                log_writer,
                Vec::new(),
                "test-fingerprint".to_string(),
                "https",
            ));
            Self {
                services,
                _temp: temp,
            }
        }

        async fn request(&self, op: &str, payload: Value) -> ResponseEnvelope {
            dispatch_service_request(
                RequestEnvelope {
                    id: "test-request".to_string(),
                    op: op.to_string(),
                    payload,
                },
                &self.services,
                0,
            )
            .await
        }
    }

    #[tokio::test]
    async fn hello_returns_versions_and_capabilities() {
        let harness = IpcHarness::new().await;

        let response = harness.request("hello", json!({})).await;

        assert!(response.ok);
        let data = response.data.unwrap();
        assert_eq!(data["protocolVersion"], IPC_PROTOCOL_VERSION);
        assert_eq!(data["daemonVersion"], env!("CARGO_PKG_VERSION"));
        assert!(data["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "get_state"));
        for capability in [
            "send_files",
            "get_transfers",
            "cancel_transfer",
            "retry_transfer",
        ] {
            assert!(data["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .any(|value| value == capability));
        }
    }

    #[tokio::test]
    async fn get_transfers_returns_registered_session() {
        let harness = IpcHarness::new().await;
        harness
            .services
            .transfers
            .register_outgoing(OutgoingTransferSpec {
                target_id: "peer-1".to_string(),
                peer_alias: "Desktop".to_string(),
                peer_fingerprint: Some("aa11".to_string()),
                source: TransferSource::Clipboard,
                items: vec![OutgoingItemSpec {
                    id: "text-1".to_string(),
                    name: "clipboard.txt".to_string(),
                    mime_type: "text/plain".to_string(),
                    size: 5,
                    payload: OutgoingPayload::Text("hello".to_string()),
                }],
            })
            .await
            .unwrap();

        let response = harness.request("get_transfers", json!({})).await;

        assert!(response.ok);
        let transfers = response.data.unwrap().as_array().unwrap().clone();
        assert_eq!(transfers.len(), 1);
        assert_eq!(transfers[0]["status"], "queued");
        assert_eq!(transfers[0]["peerAlias"], "Desktop");
    }

    #[tokio::test]
    async fn invalid_operation_returns_structured_error() {
        let harness = IpcHarness::new().await;

        let response = harness.request("not_real", json!({})).await;

        assert!(!response.ok);
        assert_eq!(response.error.unwrap().code, "unknown_operation");
    }

    #[tokio::test]
    async fn set_config_persists_and_publishes_event() {
        let harness = IpcHarness::new().await;
        let mut events = harness.services.events().subscribe();
        let mut config = harness.services.config().await;
        config.clipboard_sync_enabled = true;

        let response = harness
            .request("set_config", serde_json::to_value(config).unwrap())
            .await;

        assert!(response.ok);
        assert!(harness.services.config().await.clipboard_sync_enabled);
        assert_eq!(events.recv().await.unwrap().event, "config_changed");
    }
}
