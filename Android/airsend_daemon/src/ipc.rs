use crate::config::{AirSendConfig, ConfigStore, CONFIG_VERSION};
use crate::domain::{
    FileTransferStatus, HistoryFile, HistoryRecord, TransferDirection, TransferSource,
    TransferStatus,
};
use crate::events::EventHub;
use crate::history::{HistoryStore, SCHEMA_VERSION};
use crate::logging::SizeRotatingWriter;
use crate::protocol::{
    LegacyCommand, ParsedLine, RequestEnvelope, ResponseEnvelope, IPC_PROTOCOL_VERSION,
};
use crate::{process_command, send_data, AppState};
use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::RwLock;
use tokio::task::JoinHandle;

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
];

pub struct DaemonServices {
    config_store: ConfigStore,
    config: RwLock<AirSendConfig>,
    history: Arc<HistoryStore>,
    events: EventHub,
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
        Self {
            config_store,
            config: RwLock::new(config),
            history,
            events: EventHub::new(EVENT_CAPACITY),
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

async fn dispatch_request(request: RequestEnvelope, state: &AppState) -> ResponseEnvelope {
    let id = request.id.clone();
    match request.op.as_str() {
        "get_peers" => ResponseEnvelope::success(id, peer_snapshot(state).await),
        "send_text" => {
            let payload = match serde_json::from_value::<SendTextPayload>(request.payload) {
                Ok(payload) if !payload.text.is_empty() => payload,
                Ok(_) => return invalid_payload(id, "text must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let requested_target = payload.target_id.clone();
            let started_at_ms = now_ms_i64();
            match send_data(state, payload.target_id, &payload.text, true).await {
                Ok(target_id) => {
                    persist_outgoing_history(
                        state,
                        Some(&target_id),
                        HistoryPayload::text(&payload.text),
                        started_at_ms,
                        None,
                    )
                    .await;
                    ResponseEnvelope::success(id, json!({"completed": true, "targetId": target_id}))
                }
                Err(error) => {
                    let message = error.to_string();
                    persist_outgoing_history(
                        state,
                        requested_target.as_deref(),
                        HistoryPayload::text(&payload.text),
                        started_at_ms,
                        Some(&message),
                    )
                    .await;
                    transfer_error(id, message)
                }
            }
        }
        "send_file" => {
            let payload = match serde_json::from_value::<SendFilePayload>(request.payload) {
                Ok(payload) if !payload.path.is_empty() => payload,
                Ok(_) => return invalid_payload(id, "path must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let requested_target = payload.target_id.clone();
            let history_payload = HistoryPayload::file(&payload.path);
            let started_at_ms = now_ms_i64();
            match send_data(state, payload.target_id, &payload.path, false).await {
                Ok(target_id) => {
                    persist_outgoing_history(
                        state,
                        Some(&target_id),
                        history_payload,
                        started_at_ms,
                        None,
                    )
                    .await;
                    ResponseEnvelope::success(id, json!({"completed": true, "targetId": target_id}))
                }
                Err(error) => {
                    let message = error.to_string();
                    persist_outgoing_history(
                        state,
                        requested_target.as_deref(),
                        history_payload,
                        started_at_ms,
                        Some(&message),
                    )
                    .await;
                    transfer_error(id, message)
                }
            }
        }
        _ => {
            let peer_count = state.client.peers.lock().await.len();
            dispatch_service_request(request, &state.services, peer_count).await
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
    if lower.contains("target not found") || lower.contains("no reachable target") {
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

fn now_ms_i64() -> i64 {
    i64::try_from(now_ms()).unwrap_or(i64::MAX)
}

struct HistoryPayload {
    source: TransferSource,
    file: HistoryFile,
}

impl HistoryPayload {
    fn text(text: &str) -> Self {
        let size = text.len() as u64;
        Self {
            source: TransferSource::Clipboard,
            file: HistoryFile {
                id: uuid::Uuid::new_v4().to_string(),
                name: "clipboard.txt".to_string(),
                mime_type: "text/plain".to_string(),
                size,
                transferred_bytes: 0,
                status: FileTransferStatus::Queued,
            },
        }
    }

    fn file(path: &str) -> Self {
        let path = std::path::Path::new(path);
        let size = std::fs::metadata(path)
            .map(|value| value.len())
            .unwrap_or(0);
        Self {
            source: TransferSource::AppPicker,
            file: HistoryFile {
                id: uuid::Uuid::new_v4().to_string(),
                name: path
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or("file")
                    .to_string(),
                mime_type: "application/octet-stream".to_string(),
                size,
                transferred_bytes: 0,
                status: FileTransferStatus::Queued,
            },
        }
    }
}

async fn persist_outgoing_history(
    state: &AppState,
    peer_id: Option<&str>,
    mut payload: HistoryPayload,
    started_at_ms: i64,
    error_message: Option<&str>,
) {
    let (peer_id, peer_alias, peer_fingerprint) = if let Some(peer_id) = peer_id {
        let peers = state.client.peers.lock().await;
        if let Some((_, peer)) = peers.get(peer_id) {
            (
                peer_id.to_string(),
                peer.alias.clone(),
                Some(peer.fingerprint.clone()),
            )
        } else {
            (peer_id.to_string(), "Unknown device".to_string(), None)
        }
    } else {
        (String::new(), "Unknown device".to_string(), None)
    };

    let completed = error_message.is_none();
    payload.file.status = if completed {
        FileTransferStatus::Completed
    } else {
        FileTransferStatus::Failed
    };
    payload.file.transferred_bytes = if completed { payload.file.size } else { 0 };
    let error_code = error_message.map(transfer_error_code).map(str::to_string);
    let record = HistoryRecord {
        id: uuid::Uuid::new_v4().to_string(),
        direction: TransferDirection::Outgoing,
        source: payload.source,
        peer_id,
        peer_alias,
        peer_fingerprint,
        total_bytes: payload.file.size,
        transferred_bytes: payload.file.transferred_bytes,
        files: vec![payload.file],
        status: if completed {
            TransferStatus::Completed
        } else {
            TransferStatus::Failed
        },
        started_at_ms,
        ended_at_ms: Some(now_ms_i64()),
        saved_paths: Vec::new(),
        error_code,
        error_message: error_message.map(str::to_string),
        retryable: error_message
            .map(transfer_error_code)
            .is_some_and(|code| code != "file_not_found"),
    };
    let record_id = record.id.clone();
    match state.services.history.insert(&record) {
        Ok(()) => {
            state.services.events.publish(
                "history_changed",
                json!({"action": "insert", "id": record_id}),
            );
        }
        Err(error) => tracing::error!("Failed to persist transfer history: {error:#}"),
    }
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
