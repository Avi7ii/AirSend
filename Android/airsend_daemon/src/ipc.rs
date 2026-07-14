use crate::config::{
    AirSendConfig, ConfigStore, ManualPeer, ReceivePolicy, TransportPreference, CONFIG_VERSION,
};
use crate::domain::{TransferDirection, TransferSource, TransferStatus};
use crate::events::EventHub;
use crate::history::{HistoryStore, SCHEMA_VERSION};
use crate::logging::SizeRotatingWriter;
use crate::protocol::{
    LegacyCommand, ParsedLine, RequestEnvelope, ResponseEnvelope, IPC_PROTOCOL_VERSION,
};
use crate::transfers::{
    IncomingItemSpec, IncomingTransferSpec, OutgoingItemSpec, OutgoingPayload,
    OutgoingTransferSpec, TransferExecution, TransferService,
};
use crate::{process_command, push_text_to_app, schedule_self_restart, AppState};
use anyhow::{anyhow, Context, Result};
use futures_util::StreamExt;
use localsend::campus_fallback::MAX_FALLBACK_BYTES;
use localsend::current_network_binding;
use localsend::models::{device::DeviceInfo, file::FileMetadata};
use localsend::ports::{DISCOVERY_PORT, TRANSFER_PORT};
use localsend::transfer::session::SessionStatus;
use localsend::transfer::upload::{
    IncomingAuthorization, IncomingTransferHandler, IncomingTransferOffer,
};
use reqwest::Body;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{oneshot, watch, Mutex, RwLock, Semaphore};
use tokio::task::JoinHandle;
use tokio_util::io::ReaderStream;

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const DEFAULT_LOG_TAIL_BYTES: usize = 64 * 1024;
const MAX_LOG_TAIL_BYTES: usize = 256 * 1024;
const EVENT_CAPACITY: usize = 128;
const INCOMING_DECISION_TIMEOUT_SECS: u64 = 90;
const MAX_CLIPBOARD_BYTES: u64 = 1024 * 1024;
const IPC_HEARTBEAT_INTERVAL_SECS: u64 = 10;
const IPC_READ_TIMEOUT_SECS: u64 = 10;
const IPC_WRITE_TIMEOUT_SECS: u64 = 5;
const MAX_IPC_CONNECTIONS: usize = 16;

const CAPABILITIES: &[&str] = &[
    "hello",
    "get_snapshot",
    "subscribe",
    "get_state",
    "get_peers",
    "discover_now",
    "add_manual_peer",
    "remove_manual_peer",
    "set_preferred_target",
    "set_peer_trust",
    "get_config",
    "set_config",
    "patch_config",
    "get_history",
    "delete_history",
    "clear_history",
    "clear_history_direction",
    "get_logs",
    "clear_logs",
    "send_text",
    "send_file",
    "send_files",
    "get_transfers",
    "cancel_transfer",
    "retry_transfer",
    "accept_transfer",
    "decline_transfer",
    "restart_daemon",
];

struct IncomingSessionState {
    files: HashMap<String, FileMetadata>,
    staged_paths: HashMap<String, PathBuf>,
}

pub struct DaemonServices {
    config_store: ConfigStore,
    config: RwLock<AirSendConfig>,
    config_update: Mutex<()>,
    history: Arc<HistoryStore>,
    events: EventHub,
    transfers: TransferService,
    incoming_decisions: Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>>,
    incoming_sessions: Arc<Mutex<HashMap<String, IncomingSessionState>>>,
    ipc_slots: Arc<Semaphore>,
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
        let transfers = TransferService::new(
            history.clone(),
            events.clone(),
            config.history_limit_per_direction,
        );
        Self {
            config_store,
            config: RwLock::new(config),
            config_update: Mutex::new(()),
            history,
            events,
            transfers,
            incoming_decisions: Arc::new(Mutex::new(HashMap::new())),
            incoming_sessions: Arc::new(Mutex::new(HashMap::new())),
            ipc_slots: Arc::new(Semaphore::new(MAX_IPC_CONNECTIONS)),
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
        let sandboxed_runtime = std::env::var_os("AIRSEND_DATA_DIR").is_some();
        let reverse_ipc_ready = sandboxed_runtime
            || std::fs::read_to_string("/proc/net/unix")
                .map(|sockets| {
                    sockets
                        .lines()
                        .any(|line| line.ends_with("@airsend_app_ipc"))
                })
                .unwrap_or(false);
        let data_dir = std::env::var_os("AIRSEND_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/data/adb/airsend"));
        let storage_ready = data_dir.is_dir()
            && Path::new(&config.download_destination).is_dir()
            && Path::new(&config.media_destination).is_dir();
        let network_binding = current_network_binding()
            .map(|(interface, address)| format!("{interface} / {address}"));
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
            "tlsReady": !self.tls_fingerprint.is_empty() && self.transport_protocol == "https",
            "transportProtocol": self.transport_protocol,
            "reverseClipboardIpcReady": reverse_ipc_ready,
            "storageReady": storage_ready,
            "networkBinding": network_binding,
            "transferPort": TRANSFER_PORT,
            "discoveryPort": DISCOVERY_PORT,
        }))
    }

    async fn set_config(&self, config: AirSendConfig) -> Result<AirSendConfig> {
        let _update = self.config_update.lock().await;
        self.persist_config(config).await
    }

    async fn patch_config(&self, patch: Value) -> Result<AirSendConfig> {
        let _update = self.config_update.lock().await;
        let mut merged = serde_json::to_value(self.config.read().await.clone())?;
        let current = merged
            .as_object_mut()
            .ok_or_else(|| anyhow!("serialized config is not an object"))?;
        let patch = patch
            .as_object()
            .ok_or_else(|| anyhow!("config patch must be an object"))?;
        for (key, value) in patch {
            if !current.contains_key(key) {
                return Err(anyhow!("unknown config field: {key}"));
            }
            current.insert(key.clone(), value.clone());
        }
        let config =
            serde_json::from_value::<AirSendConfig>(merged).context("invalid config patch")?;
        self.persist_config(config).await
    }

    async fn persist_config(&self, config: AirSendConfig) -> Result<AirSendConfig> {
        let normalized = config.normalized()?;
        self.config_store.save(&normalized)?;
        let deleted = self
            .history
            .set_retention_limit_per_direction(normalized.history_limit_per_direction)?;
        self.transfers
            .set_recent_limit_per_direction(normalized.history_limit_per_direction)
            .await;
        *self.config.write().await = normalized.clone();
        if deleted > 0 {
            self.events.publish(
                "history_changed",
                json!({"action": "retention_pruned", "deleted": deleted}),
            );
        }
        self.events.publish(
            "config_changed",
            serde_json::to_value(&normalized).context("failed to encode config event")?,
        );
        Ok(normalized)
    }

    async fn decide_incoming(&self, transfer_id: &str, accepted: bool) -> Result<bool> {
        let Some(decision) = self.incoming_decisions.lock().await.remove(transfer_id) else {
            return Ok(false);
        };
        decision
            .send(accepted)
            .map_err(|_| anyhow!("incoming decision is no longer pending: {transfer_id}"))?;
        Ok(true)
    }

    async fn cleanup_incoming(&self, transfer_id: &str) {
        self.incoming_decisions.lock().await.remove(transfer_id);
        self.incoming_sessions.lock().await.remove(transfer_id);
        let _ = tokio::fs::remove_dir_all(incoming_session_dir(transfer_id)).await;
    }
}

struct IncomingAuthorizationGuard {
    transfer_id: String,
    transfers: TransferService,
    incoming_decisions: Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>>,
    incoming_sessions: Arc<Mutex<HashMap<String, IncomingSessionState>>>,
    armed: bool,
}

impl IncomingAuthorizationGuard {
    fn new(services: &DaemonServices, transfer_id: String) -> Self {
        Self {
            transfer_id,
            transfers: services.transfers.clone(),
            incoming_decisions: services.incoming_decisions.clone(),
            incoming_sessions: services.incoming_sessions.clone(),
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for IncomingAuthorizationGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let transfer_id = self.transfer_id.clone();
        let transfers = self.transfers.clone();
        let incoming_decisions = self.incoming_decisions.clone();
        let incoming_sessions = self.incoming_sessions.clone();
        runtime.spawn(async move {
            incoming_decisions.lock().await.remove(&transfer_id);
            incoming_sessions.lock().await.remove(&transfer_id);
            let _ = tokio::fs::remove_dir_all(incoming_session_dir(&transfer_id)).await;
            if transfers
                .get(&transfer_id)
                .await
                .is_some_and(|transfer| !transfer.status.is_terminal())
            {
                let _ = transfers.finish_incoming_cancelled(&transfer_id).await;
            }
        });
    }
}

enum IncomingDecision {
    Accept,
    Decline(&'static str, &'static str),
}

#[async_trait::async_trait]
impl IncomingTransferHandler for DaemonServices {
    async fn authorize(
        &self,
        offer: IncomingTransferOffer,
    ) -> std::result::Result<IncomingAuthorization, String> {
        if offer.files.len() == 1
            && offer
                .files
                .values()
                .next()
                .is_some_and(is_empty_clipboard_text_payload)
        {
            tracing::warn!("Rejected an empty incoming clipboard transfer");
            return Err("clipboard payload must not be empty".to_string());
        }
        let transfer_id = offer.session_id.clone();
        let peer_fingerprint = offer.sender.fingerprint.trim().to_ascii_lowercase();
        let peer_id = if peer_fingerprint.is_empty() {
            format!("incoming-{transfer_id}")
        } else {
            peer_fingerprint.clone()
        };
        let peer_alias = nonempty_or(&offer.sender.alias, "Unknown device");
        let items = offer
            .files
            .values()
            .map(|file| IncomingItemSpec {
                id: file.id.clone(),
                name: nonempty_or(&file.file_name, "AirSend file"),
                mime_type: nonempty_or(&file.file_type, "application/octet-stream"),
                size: file.size,
            })
            .collect::<Vec<_>>();

        self.transfers
            .register_incoming(IncomingTransferSpec {
                id: transfer_id.clone(),
                peer_id,
                peer_alias,
                peer_fingerprint: (!peer_fingerprint.is_empty())
                    .then_some(peer_fingerprint.clone()),
                items,
            })
            .await
            .map_err(|error| error.to_string())?;
        let mut authorization_guard = IncomingAuthorizationGuard::new(self, transfer_id.clone());
        self.incoming_sessions.lock().await.insert(
            transfer_id.clone(),
            IncomingSessionState {
                files: offer.files,
                staged_paths: HashMap::new(),
            },
        );

        let config = self.config().await;
        let decision = match config.receive_policy {
            ReceivePolicy::Off => {
                IncomingDecision::Decline("receiving_disabled", "Receiving is disabled")
            }
            ReceivePolicy::TrustedOnly => {
                let trusted = !peer_fingerprint.is_empty()
                    && config
                        .trusted_peer_fingerprints
                        .iter()
                        .any(|trusted| trusted.eq_ignore_ascii_case(&peer_fingerprint));
                if trusted {
                    IncomingDecision::Accept
                } else {
                    IncomingDecision::Decline(
                        "untrusted_peer",
                        "Sender is not in the trusted devices list",
                    )
                }
            }
            ReceivePolicy::Ask => {
                let (sender, receiver) = oneshot::channel();
                self.incoming_decisions
                    .lock()
                    .await
                    .insert(transfer_id.clone(), sender);
                match tokio::time::timeout(
                    std::time::Duration::from_secs(INCOMING_DECISION_TIMEOUT_SECS),
                    receiver,
                )
                .await
                {
                    Ok(Ok(true)) => IncomingDecision::Accept,
                    Ok(Ok(false)) => IncomingDecision::Decline("declined", "Transfer was declined"),
                    Ok(Err(_)) => IncomingDecision::Decline(
                        "decision_unavailable",
                        "Transfer decision channel was closed",
                    ),
                    Err(_) => {
                        IncomingDecision::Decline("decision_timeout", "Transfer request timed out")
                    }
                }
            }
        };
        self.incoming_decisions.lock().await.remove(&transfer_id);

        match decision {
            IncomingDecision::Accept => {
                self.transfers
                    .transition(&transfer_id, TransferStatus::Preparing)
                    .await
                    .map_err(|error| error.to_string())?;
                authorization_guard.disarm();
                Ok(IncomingAuthorization::Accept)
            }
            IncomingDecision::Decline(code, message) => {
                self.transfers
                    .finish_declined(&transfer_id, code, message)
                    .await
                    .map_err(|error| error.to_string())?;
                self.cleanup_incoming(&transfer_id).await;
                authorization_guard.disarm();
                Ok(IncomingAuthorization::Decline)
            }
        }
    }

    async fn staging_path(
        &self,
        session_id: &str,
        file: &FileMetadata,
    ) -> std::result::Result<PathBuf, String> {
        let sessions = self.incoming_sessions.lock().await;
        let Some(session) = sessions.get(session_id) else {
            return Err(format!("incoming session not found: {session_id}"));
        };
        if !session.files.contains_key(&file.id) {
            return Err(format!("incoming file not found: {}", file.id));
        }
        Ok(incoming_session_dir(session_id)
            .join(format!("{}.part", safe_internal_component(&file.id))))
    }

    async fn progress(
        &self,
        session_id: &str,
        file_id: &str,
        transferred_bytes: u64,
    ) -> std::result::Result<(), String> {
        self.transfers
            .set_file_progress(session_id, file_id, transferred_bytes)
            .await
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    async fn completed(
        &self,
        session_id: &str,
        file: &FileMetadata,
        staged_path: PathBuf,
    ) -> std::result::Result<bool, String> {
        self.transfers
            .set_file_progress(session_id, &file.id, file.size)
            .await
            .map_err(|error| error.to_string())?;

        let completed_session = {
            let mut sessions = self.incoming_sessions.lock().await;
            let Some(session) = sessions.get_mut(session_id) else {
                return Err(format!("incoming session not found: {session_id}"));
            };
            if !session.files.contains_key(&file.id) {
                return Err(format!("incoming file not found: {}", file.id));
            }
            session.staged_paths.insert(file.id.clone(), staged_path);
            let complete = session.staged_paths.len() == session.files.len();
            if complete {
                sessions.remove(session_id)
            } else {
                None
            }
        };

        let Some(session) = completed_session else {
            return Ok(false);
        };
        let result = finalize_incoming_session(&self.config().await, session).await;
        match result {
            Ok(finalized) => {
                self.transfers
                    .finish_completed_with_content(
                        session_id,
                        finalized.saved_paths,
                        finalized.preview_text,
                    )
                    .await
                    .map_err(|error| error.to_string())?;
                let _ = tokio::fs::remove_dir_all(incoming_session_dir(session_id)).await;
                Ok(true)
            }
            Err(error) => {
                let message = error.to_string();
                let _ = self
                    .transfers
                    .finish_failed(session_id, "receive_save_failed", &message, false)
                    .await;
                let _ = tokio::fs::remove_dir_all(incoming_session_dir(session_id)).await;
                Err(message)
            }
        }
    }

    async fn failed(&self, session_id: &str, file_id: &str, message: &str) {
        tracing::error!("Incoming transfer {session_id} file {file_id} failed: {message}");
        let _ = self
            .transfers
            .finish_failed(session_id, "receive_failed", message, false)
            .await;
        self.cleanup_incoming(session_id).await;
    }

    async fn cancelled(&self, session_id: &str) {
        let _ = self.transfers.finish_incoming_cancelled(session_id).await;
        self.cleanup_incoming(session_id).await;
    }
}

struct FinalizedIncomingSession {
    saved_paths: Vec<String>,
    preview_text: Option<String>,
}

async fn finalize_incoming_session(
    config: &AirSendConfig,
    session: IncomingSessionState,
) -> Result<FinalizedIncomingSession> {
    let single_clipboard = session.files.len() == 1;
    let mut file_ids = session.files.keys().cloned().collect::<Vec<_>>();
    file_ids.sort();
    let mut saved_paths = Vec::new();
    let mut preview_text = None;

    for file_id in file_ids {
        let file = session
            .files
            .get(&file_id)
            .ok_or_else(|| anyhow!("incoming metadata missing for {file_id}"))?;
        let staged_path = session
            .staged_paths
            .get(&file_id)
            .ok_or_else(|| anyhow!("staged file missing for {file_id}"))?;

        if single_clipboard && is_clipboard_text_payload(file) {
            let bytes = tokio::fs::read(staged_path)
                .await
                .context("failed to read incoming clipboard payload")?;
            let text =
                String::from_utf8(bytes).context("incoming clipboard payload is not UTF-8")?;
            push_text_to_app(&text)
                .await
                .context("failed to deliver incoming clipboard text to AirSend")?;
            preview_text = Some(text.chars().take(4_096).collect());
            tokio::fs::remove_file(staged_path).await.ok();
            continue;
        }

        let is_media = file.file_type.starts_with("image/") || file.file_type.starts_with("video/");
        let destination = if is_media {
            &config.media_destination
        } else {
            &config.download_destination
        };
        let saved = persist_staged_file(
            staged_path,
            Path::new(destination),
            &sanitize_file_name(&file.file_name),
        )
        .await?;
        if is_media {
            request_media_scan(&saved);
        }
        saved_paths.push(saved.to_string_lossy().into_owned());
    }

    Ok(FinalizedIncomingSession {
        saved_paths,
        preview_text,
    })
}

fn is_clipboard_text_payload(file: &FileMetadata) -> bool {
    file.size > 0 && file.size <= MAX_CLIPBOARD_BYTES && is_clipboard_text_identity(file)
}

fn is_empty_clipboard_text_payload(file: &FileMetadata) -> bool {
    is_clipboard_text_identity(file)
        && (file.size == 0
            || file
                .preview
                .as_deref()
                .is_some_and(|preview| preview.trim().is_empty()))
}

fn is_clipboard_text_identity(file: &FileMetadata) -> bool {
    if !file.file_type.eq_ignore_ascii_case("text/plain") {
        return false;
    }
    if file.file_name.eq_ignore_ascii_case("clipboard.txt") {
        return true;
    }
    let Some(stem) = file.file_name.strip_suffix(".txt") else {
        return false;
    };
    (10..=13).contains(&stem.len()) && stem.bytes().all(|byte| byte.is_ascii_digit())
}

fn is_blank_text_payload(text: &str) -> bool {
    text.trim().is_empty()
}

async fn persist_staged_file(
    staged_path: &Path,
    destination: &Path,
    name: &str,
) -> Result<PathBuf> {
    tokio::fs::create_dir_all(destination)
        .await
        .with_context(|| format!("failed to create {}", destination.display()))?;
    let final_path = available_destination_path(destination, name).await?;
    let temp_path = destination.join(format!(".airsend-{}.part", uuid::Uuid::new_v4()));
    tokio::fs::copy(staged_path, &temp_path)
        .await
        .with_context(|| format!("failed to copy {}", staged_path.display()))?;
    tokio::fs::File::open(&temp_path).await?.sync_all().await?;
    if let Err(error) = tokio::fs::rename(&temp_path, &final_path).await {
        tokio::fs::remove_file(&temp_path).await.ok();
        return Err(error).with_context(|| format!("failed to save {}", final_path.display()));
    }
    tokio::fs::remove_file(staged_path).await.ok();
    Ok(final_path)
}

async fn available_destination_path(destination: &Path, name: &str) -> Result<PathBuf> {
    for index in 0..10_000u32 {
        let candidate_name = if index == 0 {
            name.to_string()
        } else {
            numbered_file_name(name, index)
        };
        let candidate = destination.join(candidate_name);
        if !tokio::fs::try_exists(&candidate).await? {
            return Ok(candidate);
        }
    }
    Err(anyhow!("too many conflicting files named {name}"))
}

fn numbered_file_name(name: &str, index: u32) -> String {
    let path = Path::new(name);
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("AirSend file");
    match path.extension().and_then(|value| value.to_str()) {
        Some(extension) if !extension.is_empty() => format!("{stem} ({index}).{extension}"),
        _ => format!("{stem} ({index})"),
    }
}

fn sanitize_file_name(value: &str) -> String {
    let base = value
        .rsplit(['/', '\\'])
        .find(|part| !part.is_empty())
        .unwrap_or("AirSend file");
    let sanitized = base
        .chars()
        .map(|character| {
            if character.is_control() || matches!(character, '/' | '\\') {
                '_'
            } else {
                character
            }
        })
        .collect::<String>();
    let sanitized = sanitized.trim().trim_matches('.');
    if sanitized.is_empty() {
        "AirSend file".to_string()
    } else {
        sanitized.chars().take(240).collect()
    }
}

fn safe_internal_component(value: &str) -> String {
    let value = value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '_'
            }
        })
        .take(96)
        .collect::<String>();
    if value.is_empty() {
        "item".to_string()
    } else {
        value
    }
}

fn incoming_session_dir(session_id: &str) -> PathBuf {
    let root = std::env::var_os("AIRSEND_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/data/adb/airsend"));
    root.join("incoming")
        .join(safe_internal_component(session_id))
}

fn request_media_scan(path: &Path) {
    let uri = format!("file://{}", path.display());
    if let Err(error) = Command::new("am")
        .args([
            "broadcast",
            "-a",
            "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
            "-d",
            &uri,
        ])
        .spawn()
    {
        tracing::warn!(
            "Failed to request media scan for {}: {error}",
            path.display()
        );
    }
}

fn nonempty_or(value: &str, fallback: &str) -> String {
    let value = value.trim();
    if value.is_empty() {
        fallback.to_string()
    } else {
        value.to_string()
    }
}

pub async fn handle_client(stream: UnixStream, state: Arc<AppState>) -> Result<()> {
    let _ipc_slot = tokio::time::timeout(
        Duration::from_secs(1),
        state.services.ipc_slots.clone().acquire_owned(),
    )
    .await
    .context("timed out waiting for an AirSend IPC slot")??;
    let (reader, writer) = stream.into_split();
    let writer = Arc::new(tokio::sync::Mutex::new(writer));
    let mut reader = BufReader::new(reader);
    let mut line = Vec::new();
    let mut event_forwarder: Option<JoinHandle<()>> = None;

    loop {
        line.clear();
        let bytes_read = if event_forwarder.is_some() {
            reader.read_until(b'\n', &mut line).await?
        } else {
            tokio::time::timeout(
                Duration::from_secs(IPC_READ_TIMEOUT_SECS),
                reader.read_until(b'\n', &mut line),
            )
            .await
            .context("timed out waiting for an AirSend IPC request")??
        };
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
                if should_keep_ipc_connection(subscribe, response.ok) && event_forwarder.is_none() {
                    event_forwarder = Some(spawn_event_forwarder(
                        state.services.events().subscribe(),
                        writer.clone(),
                    ));
                } else {
                    break;
                }
            }
            Ok(ParsedLine::Legacy(LegacyCommand::GetPeers)) => {
                let peers = peer_snapshot(&state).await;
                write_json_line(&writer, &peers).await?;
                break;
            }
            Ok(ParsedLine::Legacy(command)) => {
                let state = state.clone();
                tokio::spawn(async move {
                    if let Err(error) = process_command(command, &state).await {
                        tracing::error!("Legacy IPC command failed: {error:#}");
                    }
                });
                break;
            }
            Err(error) => {
                tracing::warn!("Invalid IPC command: {error:#}");
                break;
            }
        }
    }

    if let Some(forwarder) = event_forwarder {
        forwarder.abort();
    }
    Ok(())
}

fn should_keep_ipc_connection(subscribe: bool, response_ok: bool) -> bool {
    subscribe && response_ok
}

async fn dispatch_request(request: RequestEnvelope, state: &Arc<AppState>) -> ResponseEnvelope {
    let id = request.id.clone();
    match request.op.as_str() {
        "get_snapshot" => {
            let peers = peer_snapshot(state).await;
            let peer_count = state.client.peers.lock().await.len();
            let response = dispatch_service_request(request, &state.services, peer_count).await;
            if !response.ok {
                return response;
            }
            let mut data = response.data.unwrap_or_else(|| json!({}));
            if let Some(object) = data.as_object_mut() {
                object.insert("peers".to_string(), peers);
            }
            ResponseEnvelope::success(id, data)
        }
        "get_peers" => ResponseEnvelope::success(id, peer_snapshot(state).await),
        "discover_now" => {
            state.client.refresh_peers().await;
            let announcement = state.client.announce(None).await;
            let discovered = state.client.discover_subnet_peers().await;
            match announcement {
                Ok(()) => {
                    state
                        .services
                        .events
                        .publish("peers_changed", json!({"reason": "discovery_requested"}));
                    ResponseEnvelope::success(
                        id,
                        json!({"started": true, "discovered": discovered}),
                    )
                }
                Err(error) => ResponseEnvelope::error(
                    id,
                    "discovery_failed",
                    format!("Failed to announce AirSend device: {error}"),
                ),
            }
        }
        "set_preferred_target" => {
            let payload = match serde_json::from_value::<PreferredTargetPayload>(request.payload) {
                Ok(payload) => payload,
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let target_id = payload
                .target_id
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string);
            let mut config = state.services.config().await;
            let mut target_fingerprint = None;
            if let Some(target_id) = target_id.as_deref() {
                let online_peer = state.client.peers.lock().await.get(target_id).cloned();
                let online = online_peer.is_some();
                let configured_peer = config.manual_peers.iter().find(|peer| {
                    peer.id == target_id || peer.fingerprint.as_deref() == Some(target_id)
                });
                if !online && configured_peer.is_none() {
                    return ResponseEnvelope::error(
                        id,
                        "peer_not_found",
                        "Preferred target is not known",
                    );
                }
                target_fingerprint = online_peer.map(|(_, peer)| peer.fingerprint).or_else(|| {
                    configured_peer
                        .map(|peer| peer.fingerprint.clone().unwrap_or_else(|| peer.id.clone()))
                });
            }
            config.preferred_target = target_id;
            if config.receive_policy == ReceivePolicy::TrustedOnly {
                if let Some(fingerprint) = target_fingerprint
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_ascii_lowercase)
                {
                    if !config
                        .trusted_peer_fingerprints
                        .iter()
                        .any(|trusted| trusted.eq_ignore_ascii_case(&fingerprint))
                    {
                        config.trusted_peer_fingerprints.push(fingerprint);
                    }
                }
            }
            match state.services.set_config(config).await {
                Ok(config) => ResponseEnvelope::success(
                    id,
                    json!({"preferredTarget": config.preferred_target}),
                ),
                Err(error) => {
                    ResponseEnvelope::error(id, "config_update_failed", error.to_string())
                }
            }
        }
        "set_peer_trust" => {
            let payload = match serde_json::from_value::<PeerTrustPayload>(request.payload) {
                Ok(payload) if !payload.fingerprint.trim().is_empty() => payload,
                Ok(_) => return invalid_payload(id, "fingerprint must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let fingerprint = payload.fingerprint.trim().to_ascii_lowercase();
            let mut config = state.services.config().await;
            config
                .trusted_peer_fingerprints
                .retain(|value| !value.eq_ignore_ascii_case(&fingerprint));
            if payload.trusted {
                config.trusted_peer_fingerprints.push(fingerprint.clone());
            }
            match state.services.set_config(config).await {
                Ok(_) => ResponseEnvelope::success(
                    id,
                    json!({"fingerprint": fingerprint, "trusted": payload.trusted}),
                ),
                Err(error) => {
                    ResponseEnvelope::error(id, "config_update_failed", error.to_string())
                }
            }
        }
        "add_manual_peer" => {
            let payload = match serde_json::from_value::<AddManualPeerPayload>(request.payload) {
                Ok(payload) => payload,
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            match add_manual_peer(state, payload).await {
                Ok(peer) => ResponseEnvelope::success(id, peer),
                Err(error) => {
                    ResponseEnvelope::error(id, "manual_peer_unreachable", error.to_string())
                }
            }
        }
        "remove_manual_peer" => {
            let payload = match serde_json::from_value::<RemoveManualPeerPayload>(request.payload) {
                Ok(payload) if !payload.id.trim().is_empty() => payload,
                Ok(_) => return invalid_payload(id, "id must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let mut config = state.services.config().await;
            let before = config.manual_peers.len();
            let removed_fingerprints = config
                .manual_peers
                .iter()
                .filter(|peer| peer.id == payload.id)
                .filter_map(|peer| peer.fingerprint.clone())
                .collect::<Vec<_>>();
            config.manual_peers.retain(|peer| peer.id != payload.id);
            if config.manual_peers.len() == before {
                return ResponseEnvelope::success(id, json!({"removed": false}));
            }
            if config.preferred_target.as_deref() == Some(payload.id.as_str())
                || config
                    .preferred_target
                    .as_ref()
                    .is_some_and(|target| removed_fingerprints.contains(target))
            {
                config.preferred_target = None;
            }
            match state.services.set_config(config).await {
                Ok(_) => {
                    let mut peers = state.client.peers.lock().await;
                    peers.remove(&payload.id);
                    for fingerprint in removed_fingerprints {
                        peers.remove(&fingerprint);
                    }
                    drop(peers);
                    state
                        .services
                        .events
                        .publish("peers_changed", json!({"reason": "manual_peer_removed"}));
                    ResponseEnvelope::success(id, json!({"removed": true}))
                }
                Err(error) => {
                    ResponseEnvelope::error(id, "config_update_failed", error.to_string())
                }
            }
        }
        "restart_daemon" => {
            tokio::spawn(async {
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                if let Err(error) = schedule_self_restart() {
                    tracing::error!("Failed to schedule daemon restart: {error:#}");
                }
                // Root mode exits into the module supervisor; no-root mode has already
                // scheduled its bundled-daemon replacement above.
                std::process::exit(0);
            });
            ResponseEnvelope::success(id, json!({"restartScheduled": true}))
        }
        "send_text" => {
            let payload = match serde_json::from_value::<SendTextPayload>(request.payload) {
                Ok(payload) if !is_blank_text_payload(&payload.text) => payload,
                Ok(_) => return invalid_payload(id, "text must not be blank"),
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
        "accept_transfer" | "decline_transfer" => {
            let payload = match serde_json::from_value::<TransferIdPayload>(request.payload) {
                Ok(payload) if !payload.id.trim().is_empty() => payload,
                Ok(_) => return invalid_payload(id, "id must not be empty"),
                Err(error) => return invalid_payload(id, &error.to_string()),
            };
            let Some(record) = state.services.transfers.get(&payload.id).await else {
                return ResponseEnvelope::error(id, "transfer_not_found", "Transfer not found");
            };
            if record.direction != TransferDirection::Incoming
                || record.status != TransferStatus::AwaitingAcceptance
            {
                return ResponseEnvelope::error(
                    id,
                    "transfer_not_pending",
                    "Incoming transfer is not awaiting a decision",
                );
            }
            let accepted = request.op == "accept_transfer";
            match state.services.decide_incoming(&payload.id, accepted).await {
                Ok(true) => ResponseEnvelope::success(
                    id,
                    json!({"decisionRecorded": true, "accepted": accepted}),
                ),
                Ok(false) => ResponseEnvelope::error(
                    id,
                    "transfer_not_pending",
                    "Incoming transfer decision is no longer pending",
                ),
                Err(error) => transfer_error(id, error.to_string()),
            }
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
            if record.direction == TransferDirection::Incoming {
                if record.status == TransferStatus::AwaitingAcceptance {
                    return match state.services.decide_incoming(&payload.id, false).await {
                        Ok(cancelled) => {
                            ResponseEnvelope::success(id, json!({"cancelRequested": cancelled}))
                        }
                        Err(error) => transfer_error(id, error.to_string()),
                    };
                }
                let cancelled = {
                    let mut sessions = state.client.sessions.lock().await;
                    if let Some(session) = sessions.get_mut(&payload.id) {
                        session.status = SessionStatus::Cancelled;
                        true
                    } else {
                        false
                    }
                };
                if cancelled {
                    let _ = state
                        .services
                        .transfers
                        .finish_incoming_cancelled(&payload.id)
                        .await;
                    state.services.cleanup_incoming(&payload.id).await;
                }
                return ResponseEnvelope::success(id, json!({"cancelRequested": cancelled}));
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

pub(crate) async fn queue_background_file(
    state: &Arc<AppState>,
    target_id: String,
    path: PathBuf,
    source: TransferSource,
) -> Result<String> {
    let metadata = tokio::fs::metadata(&path)
        .await
        .with_context(|| format!("failed to read {}", path.display()))?;
    if !metadata.is_file() {
        return Err(anyhow!("path is not a file: {}", path.display()));
    }
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("file")
        .to_string();
    queue_background_items(
        state,
        target_id,
        source,
        vec![OutgoingItemSpec {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            mime_type: crate::infer_campus_mime_type(&path),
            size: metadata.len(),
            payload: OutgoingPayload::File(path),
        }],
    )
    .await
}

pub(crate) async fn queue_background_text(
    state: &Arc<AppState>,
    target_id: String,
    text: String,
    source: TransferSource,
) -> Result<String> {
    if is_blank_text_payload(&text) {
        return Err(anyhow!("text payload must not be blank"));
    }
    let size = text.len() as u64;
    queue_background_items(
        state,
        target_id,
        source,
        vec![OutgoingItemSpec {
            id: uuid::Uuid::new_v4().to_string(),
            name: "clipboard.txt".to_string(),
            mime_type: "text/plain".to_string(),
            size,
            payload: OutgoingPayload::Text(text),
        }],
    )
    .await
}

async fn queue_background_items(
    state: &Arc<AppState>,
    target_id: String,
    source: TransferSource,
    items: Vec<OutgoingItemSpec>,
) -> Result<String> {
    let (peer_alias, peer_fingerprint) = {
        let peers = state.client.peers.lock().await;
        peers
            .get(&target_id)
            .map(|(_, peer)| (peer.alias.clone(), Some(peer.fingerprint.clone())))
            .unwrap_or_else(|| (target_id.clone(), None))
    };
    let execution = state
        .services
        .transfers
        .register_outgoing(OutgoingTransferSpec {
            target_id,
            peer_alias,
            peer_fingerprint,
            source,
            items,
        })
        .await?;
    let transfer_id = execution.transfer_id.clone();
    let task_state = state.clone();
    tokio::spawn(async move {
        run_outgoing_transfer(task_state, execution).await;
    });
    Ok(transfer_id)
}

async fn add_manual_peer(state: &Arc<AppState>, payload: AddManualPeerPayload) -> Result<Value> {
    let address = payload.address.trim().trim_matches(['[', ']']).to_string();
    if address.is_empty() {
        return Err(anyhow!("manual peer address must not be empty"));
    }
    if payload.port == 0 {
        return Err(anyhow!("manual peer port must be greater than zero"));
    }
    let mut resolved = tokio::net::lookup_host((address.as_str(), payload.port))
        .await
        .with_context(|| format!("failed to resolve {address}"))?;
    let mut socket_addr = resolved
        .next()
        .ok_or_else(|| anyhow!("address did not resolve: {address}"))?;
    let config = state.services.config().await;
    let protocol = match config.transport_preference {
        TransportPreference::Https => "https",
        TransportPreference::HttpCompatibility => "http",
    };
    let url = format!(
        "{protocol}://{}:{}/api/localsend/v2/info",
        url_host(&address),
        payload.port
    );
    let response = state
        .client
        .http_client
        .get(&url)
        .header("Connection", "close")
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await
        .with_context(|| format!("failed to probe {url}"))?;
    if !response.status().is_success() {
        return Err(anyhow!("manual peer returned HTTP {}", response.status()));
    }
    let mut info = response
        .json::<DeviceInfo>()
        .await
        .context("manual peer returned invalid device information")?;
    let fingerprint = info.fingerprint.trim().to_ascii_lowercase();
    if fingerprint.is_empty() {
        return Err(anyhow!("manual peer did not provide a fingerprint"));
    }
    if let Some(expected) = payload
        .fingerprint
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        if !expected.eq_ignore_ascii_case(&fingerprint) {
            return Err(anyhow!(
                "manual peer fingerprint mismatch: expected {expected}, received {fingerprint}"
            ));
        }
    }
    info.fingerprint = fingerprint.clone();
    socket_addr.set_port(info.port);
    let alias = nonempty_or(&payload.alias, &info.alias);

    let mut updated = config;
    updated.manual_peers.retain(|peer| {
        peer.id != fingerprint
            && !(peer.address.eq_ignore_ascii_case(&address) && peer.port == payload.port)
    });
    updated.manual_peers.push(ManualPeer {
        id: fingerprint.clone(),
        alias: alias.clone(),
        address: address.clone(),
        port: payload.port,
        fingerprint: Some(fingerprint.clone()),
    });
    state.services.set_config(updated).await?;
    state
        .client
        .peers
        .lock()
        .await
        .insert(fingerprint.clone(), (socket_addr, info.clone()));
    state.services.events.publish(
        "peers_changed",
        json!({"reason": "manual_peer_added", "id": fingerprint}),
    );

    Ok(json!({
        "id": fingerprint,
        "alias": alias,
        "deviceModel": info.device_model,
        "deviceType": info.device_type,
        "version": info.version,
        "fingerprint": info.fingerprint,
        "address": socket_addr.to_string(),
        "protocol": info.protocol,
        "selected": false,
        "manual": true,
        "online": true,
    }))
}

fn url_host(address: &str) -> String {
    if address.contains(':') && !address.starts_with('[') {
        format!("[{address}]")
    } else {
        address.to_string()
    }
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
                    if item.size > MAX_FALLBACK_BYTES as u64 {
                        return Err(anyhow!(
                            "campus fallback only supports files up to {} bytes",
                            MAX_FALLBACK_BYTES
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
            | "get_snapshot"
            | "subscribe"
            | "get_state"
            | "get_config"
            | "set_config"
            | "patch_config"
            | "get_history"
            | "delete_history"
            | "clear_history"
            | "clear_history_direction"
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
            "get_snapshot" => {
                let config = services.config().await;
                let history_limit = config
                    .history_limit_per_direction
                    .saturating_mul(2)
                    .min(500);
                Ok(json!({
                    "daemon": services.state_snapshot(peer_count).await?,
                    "config": config,
                    "transfers": services.transfers.list().await,
                    "history": services.history.list(history_limit)?,
                }))
            }
            "subscribe" => Ok(json!({"subscribed": true})),
            "get_state" => services.state_snapshot(peer_count).await,
            "get_config" => Ok(serde_json::to_value(services.config().await)?),
            "set_config" => {
                let config = serde_json::from_value::<AirSendConfig>(request.payload)
                    .context("invalid config payload")?;
                Ok(serde_json::to_value(services.set_config(config).await?)?)
            }
            "patch_config" => Ok(serde_json::to_value(
                services.patch_config(request.payload).await?,
            )?),
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
                    services.transfers.forget_terminal(&payload.id).await;
                    services.events.publish(
                        "history_changed",
                        json!({"action": "delete", "id": payload.id}),
                    );
                }
                Ok(json!({"deleted": deleted}))
            }
            "clear_history" => {
                let deleted = services.history.clear()?;
                services.transfers.forget_all_terminal().await;
                services.events.publish(
                    "history_changed",
                    json!({"action": "clear", "deleted": deleted}),
                );
                Ok(json!({"deleted": deleted}))
            }
            "clear_history_direction" => {
                let payload =
                    serde_json::from_value::<ClearHistoryDirectionPayload>(request.payload)
                        .context("invalid history direction payload")?;
                let deleted = services.history.clear_direction(&payload.direction)?;
                services
                    .transfers
                    .forget_terminal_direction(&payload.direction)
                    .await;
                services.events.publish(
                    "history_changed",
                    json!({
                        "action": "clear_direction",
                        "direction": payload.direction,
                        "deleted": deleted
                    }),
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
        Err(error) => ResponseEnvelope::error(id, "operation_failed", format!("{error:#}")),
    }
}

async fn peer_snapshot(state: &AppState) -> Value {
    let config = state.services.config().await;
    let preferred_target = config.preferred_target.as_deref();
    let peers = state.client.peers.lock().await;
    let mut snapshots = peers
        .iter()
        .map(|(id, (address, info))| {
            let manual = config.manual_peers.iter().any(|peer| {
                peer.id == *id
                    || peer
                        .fingerprint
                        .as_deref()
                        .is_some_and(|fingerprint| fingerprint.eq_ignore_ascii_case(id))
            });
            json!({
                "id": id,
                "alias": info.alias,
                "deviceModel": info.device_model,
                "deviceType": info.device_type,
                "version": info.version,
                "fingerprint": info.fingerprint,
                "address": address.to_string(),
                "protocol": info.protocol,
                "selected": preferred_target == Some(id.as_str()),
                "manual": manual,
                "online": true,
            })
        })
        .collect::<Vec<_>>();
    for manual in &config.manual_peers {
        let fingerprint = manual.fingerprint.as_deref().unwrap_or(&manual.id);
        let online = peers.keys().any(|id| id.eq_ignore_ascii_case(fingerprint));
        if online {
            continue;
        }
        let protocol = match config.transport_preference {
            TransportPreference::Https => "https",
            TransportPreference::HttpCompatibility => "http",
        };
        snapshots.push(json!({
            "id": manual.id,
            "alias": manual.alias,
            "deviceModel": Value::Null,
            "deviceType": Value::Null,
            "version": "",
            "fingerprint": fingerprint,
            "address": format!("{}:{}", url_host(&manual.address), manual.port),
            "protocol": protocol,
            "selected": preferred_target == Some(manual.id.as_str()),
            "manual": true,
            "online": false,
        }));
    }
    Value::Array(snapshots)
}

fn spawn_event_forwarder(
    mut receiver: tokio::sync::broadcast::Receiver<crate::protocol::EventEnvelope>,
    writer: Arc<tokio::sync::Mutex<tokio::net::unix::OwnedWriteHalf>>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut heartbeat = tokio::time::interval(Duration::from_secs(IPC_HEARTBEAT_INTERVAL_SECS));
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        heartbeat.tick().await;
        loop {
            tokio::select! {
                event = receiver.recv() => {
                    match event {
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
                _ = heartbeat.tick() => {
                    let event = crate::protocol::EventEnvelope::new(
                        "heartbeat",
                        0,
                        json!({}),
                    );
                    if write_json_line(&writer, &event).await.is_err() {
                        break;
                    }
                }
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
    tokio::time::timeout(Duration::from_secs(IPC_WRITE_TIMEOUT_SECS), async {
        writer.lock().await.write_all(&bytes).await
    })
    .await
    .context("timed out writing IPC response")??;
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreferredTargetPayload {
    #[serde(default)]
    target_id: Option<String>,
}

#[derive(Deserialize)]
struct PeerTrustPayload {
    fingerprint: String,
    trusted: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AddManualPeerPayload {
    #[serde(default)]
    alias: String,
    address: String,
    port: u16,
    #[serde(default)]
    fingerprint: Option<String>,
}

#[derive(Deserialize)]
struct RemoveManualPeerPayload {
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

#[derive(Deserialize)]
struct ClearHistoryDirectionPayload {
    direction: TransferDirection,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LogTailPayload {
    max_bytes: Option<usize>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::HistoryRecord;
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
            "get_snapshot",
            "send_files",
            "get_transfers",
            "cancel_transfer",
            "retry_transfer",
            "accept_transfer",
            "decline_transfer",
            "discover_now",
            "add_manual_peer",
            "remove_manual_peer",
            "set_preferred_target",
            "set_peer_trust",
            "patch_config",
            "restart_daemon",
        ] {
            assert!(data["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .any(|value| value == capability));
        }
    }

    #[tokio::test]
    async fn get_snapshot_returns_the_refresh_payload_in_one_response() {
        let harness = IpcHarness::new().await;

        let response = harness.request("get_snapshot", json!({})).await;

        assert!(response.ok);
        let data = response.data.unwrap();
        assert!(data["daemon"].is_object());
        assert!(data["config"].is_object());
        assert!(data["transfers"].is_array());
        assert!(data["history"].is_array());
    }

    #[test]
    fn only_successful_subscriptions_keep_ipc_connections_open() {
        assert!(!should_keep_ipc_connection(false, true));
        assert!(!should_keep_ipc_connection(true, false));
        assert!(should_keep_ipc_connection(true, true));
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

    #[test]
    fn blank_text_payload_validation_preserves_meaningful_whitespace() {
        assert!(is_blank_text_payload(""));
        assert!(is_blank_text_payload(" \n\t"));
        assert!(!is_blank_text_payload(" hello \n"));
    }

    #[tokio::test]
    async fn empty_incoming_clipboard_is_rejected_without_history() {
        let harness = IpcHarness::new().await;

        let result = harness
            .services
            .authorize(IncomingTransferOffer {
                session_id: "incoming-empty-clipboard".to_string(),
                sender: DeviceInfo {
                    alias: "Desktop".to_string(),
                    fingerprint: "AA11".to_string(),
                    ..Default::default()
                },
                files: HashMap::from([(
                    "clipboard".to_string(),
                    FileMetadata {
                        id: "clipboard".to_string(),
                        file_name: "clipboard.txt".to_string(),
                        size: 0,
                        file_type: "text/plain".to_string(),
                        sha256: None,
                        preview: Some(String::new()),
                        metadata: None,
                    },
                )]),
            })
            .await;

        assert_eq!(result.unwrap_err(), "clipboard payload must not be empty");
        assert!(harness.services.transfers.list().await.is_empty());
        assert!(harness.services.history.list(10).unwrap().is_empty());
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

    #[tokio::test]
    async fn concurrent_config_patches_merge_without_lost_updates() {
        let harness = IpcHarness::new().await;

        let (clipboard, screenshot) = tokio::join!(
            harness.request("patch_config", json!({"clipboardSyncEnabled": false})),
            harness.request("patch_config", json!({"screenshotSyncEnabled": false}))
        );

        assert!(clipboard.ok);
        assert!(screenshot.ok);
        let config = harness.services.config().await;
        assert!(!config.clipboard_sync_enabled);
        assert!(!config.screenshot_sync_enabled);
        assert_eq!(harness.services.config_store.load().unwrap(), config);
    }

    #[tokio::test]
    async fn config_patch_rejects_unknown_fields_without_writing() {
        let harness = IpcHarness::new().await;
        let before = harness.services.config().await;

        let response = harness
            .request("patch_config", json!({"screenshotSyncEnabledd": false}))
            .await;

        assert!(!response.ok);
        assert_eq!(harness.services.config().await, before);
        assert_eq!(harness.services.config_store.load().unwrap(), before);
    }

    #[tokio::test]
    async fn disconnected_incoming_offer_does_not_leave_an_orphaned_transfer() {
        let harness = IpcHarness::new().await;
        let services = harness.services.clone();
        let task = tokio::spawn(async move {
            services
                .authorize(IncomingTransferOffer {
                    session_id: "incoming-disconnected".to_string(),
                    sender: DeviceInfo {
                        alias: "Disconnected desktop".to_string(),
                        fingerprint: "BB22".to_string(),
                        ..Default::default()
                    },
                    files: HashMap::from([(
                        "file-1".to_string(),
                        FileMetadata {
                            id: "file-1".to_string(),
                            file_name: "interrupted.txt".to_string(),
                            size: 4,
                            file_type: "text/plain".to_string(),
                            sha256: None,
                            preview: None,
                            metadata: None,
                        },
                    )]),
                })
                .await
        });

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                if harness
                    .services
                    .incoming_decisions
                    .lock()
                    .await
                    .contains_key("incoming-disconnected")
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                let history = harness.services.history.list(10).unwrap();
                if !history.is_empty() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        let history = harness.services.history.list(10).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].status, TransferStatus::Cancelled);
        assert_eq!(history[0].error_code.as_deref(), Some("sender_cancelled"));
        assert!(!harness
            .services
            .incoming_decisions
            .lock()
            .await
            .contains_key("incoming-disconnected"));
        assert!(!harness
            .services
            .incoming_sessions
            .lock()
            .await
            .contains_key("incoming-disconnected"));
    }

    #[tokio::test]
    async fn deleting_history_also_removes_the_terminal_transfer_snapshot() {
        let harness = IpcHarness::new().await;
        harness
            .services
            .transfers
            .register_incoming(IncomingTransferSpec {
                id: "incoming-delete".to_string(),
                peer_id: "peer-1".to_string(),
                peer_alias: "Desktop".to_string(),
                peer_fingerprint: Some("cc33".to_string()),
                items: vec![IncomingItemSpec {
                    id: "file-1".to_string(),
                    name: "done.txt".to_string(),
                    mime_type: "text/plain".to_string(),
                    size: 4,
                }],
            })
            .await
            .unwrap();
        harness
            .services
            .transfers
            .finish_declined("incoming-delete", "declined", "Transfer was declined")
            .await
            .unwrap();

        let response = harness
            .request("delete_history", json!({"id": "incoming-delete"}))
            .await;

        assert!(response.ok);
        assert_eq!(response.data.unwrap()["deleted"], true);
        assert!(harness.services.history.list(10).unwrap().is_empty());
        assert!(harness.services.transfers.list().await.is_empty());
    }

    #[tokio::test]
    async fn clearing_history_by_direction_preserves_the_other_tab() {
        let harness = IpcHarness::new().await;
        let outgoing = HistoryRecord::completed_for_test(1);
        let mut incoming = HistoryRecord::completed_for_test(2);
        incoming.id = "incoming-history".to_string();
        incoming.direction = TransferDirection::Incoming;
        harness.services.history.insert(&outgoing).unwrap();
        harness.services.history.insert(&incoming).unwrap();

        let response = harness
            .request("clear_history_direction", json!({"direction": "outgoing"}))
            .await;

        assert!(response.ok);
        assert_eq!(response.data.unwrap()["deleted"], 1);
        assert_eq!(harness.services.history.list(10).unwrap(), vec![incoming]);
    }

    #[tokio::test]
    async fn receiving_off_declines_and_persists_the_request() {
        let harness = IpcHarness::new().await;
        let mut config = harness.services.config().await;
        config.receive_policy = ReceivePolicy::Off;
        harness.services.set_config(config).await.unwrap();
        let sender = localsend::models::device::DeviceInfo {
            alias: "Desktop".to_string(),
            fingerprint: "AA11".to_string(),
            ..Default::default()
        };
        let files = HashMap::from([(
            "file-1".to_string(),
            FileMetadata {
                id: "file-1".to_string(),
                file_name: "note.txt".to_string(),
                size: 4,
                file_type: "text/plain".to_string(),
                sha256: None,
                preview: None,
                metadata: None,
            },
        )]);

        let decision = harness
            .services
            .authorize(IncomingTransferOffer {
                session_id: "incoming-off".to_string(),
                sender,
                files,
            })
            .await
            .unwrap();

        assert_eq!(decision, IncomingAuthorization::Decline);
        let history = harness.services.history.list(10).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].status, TransferStatus::Declined);
        assert_eq!(history[0].error_code.as_deref(), Some("receiving_disabled"));
    }

    #[test]
    fn incoming_names_cannot_escape_the_destination() {
        assert_eq!(sanitize_file_name("../../secret.txt"), "secret.txt");
        assert_eq!(sanitize_file_name("..\\..\\photo.jpg"), "photo.jpg");
        assert_eq!(safe_internal_component("../session"), "___session");
        assert_eq!(numbered_file_name("photo.jpg", 2), "photo (2).jpg");
        assert_eq!(url_host("192.168.1.2"), "192.168.1.2");
        assert_eq!(url_host("fe80::1"), "[fe80::1]");
    }

    #[test]
    fn clipboard_text_is_not_exposed_as_a_download() {
        let metadata = |name: &str, mime_type: &str| FileMetadata {
            id: "clipboard".to_string(),
            file_name: name.to_string(),
            size: 42,
            file_type: mime_type.to_string(),
            sha256: None,
            preview: None,
            metadata: None,
        };

        assert!(is_clipboard_text_payload(&metadata(
            "clipboard.txt",
            "text/plain"
        )));
        assert!(is_clipboard_text_payload(&metadata(
            "1783913007.txt",
            "text/plain"
        )));
        assert!(!is_clipboard_text_payload(&metadata(
            "notes.txt",
            "text/plain"
        )));
        assert!(!is_clipboard_text_payload(&metadata(
            "1783913007.txt",
            "application/octet-stream"
        )));

        let mut empty = metadata("clipboard.txt", "text/plain");
        empty.size = 0;
        empty.preview = Some(String::new());
        assert!(is_empty_clipboard_text_payload(&empty));
        assert!(!is_clipboard_text_payload(&empty));

        let mut blank = metadata("clipboard.txt", "text/plain");
        blank.preview = Some(" \n\t".to_string());
        assert!(is_empty_clipboard_text_payload(&blank));
    }
}
