use crate::domain::{
    FileTransferStatus, HistoryFile, HistoryRecord, TransferDirection, TransferSource,
    TransferStatus,
};
use crate::events::EventHub;
use crate::history::HistoryStore;
use anyhow::{anyhow, Result};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{watch, Mutex, RwLock};

#[derive(Debug, Clone)]
pub enum OutgoingPayload {
    Text(String),
    File(PathBuf),
}

#[derive(Debug, Clone)]
pub struct OutgoingItemSpec {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub size: u64,
    pub payload: OutgoingPayload,
}

#[derive(Debug, Clone)]
pub struct OutgoingTransferSpec {
    pub target_id: String,
    pub peer_alias: String,
    pub peer_fingerprint: Option<String>,
    pub source: TransferSource,
    pub items: Vec<OutgoingItemSpec>,
}

#[derive(Debug, Clone)]
pub struct IncomingItemSpec {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub size: u64,
}

#[derive(Debug, Clone)]
pub struct IncomingTransferSpec {
    pub id: String,
    pub peer_id: String,
    pub peer_alias: String,
    pub peer_fingerprint: Option<String>,
    pub items: Vec<IncomingItemSpec>,
}

pub struct TransferExecution {
    pub transfer_id: String,
    pub spec: OutgoingTransferSpec,
    pub cancel: watch::Receiver<bool>,
}

struct TerminalOutcome<'a> {
    status: TransferStatus,
    error_code: Option<&'a str>,
    error_message: Option<&'a str>,
    retryable: bool,
    saved_paths: Option<Vec<String>>,
    preview_text: Option<String>,
}

#[derive(Clone)]
pub struct TransferService {
    inner: Arc<TransferServiceInner>,
}

struct TransferServiceInner {
    transfers: RwLock<HashMap<String, HistoryRecord>>,
    retry_specs: RwLock<HashMap<String, OutgoingTransferSpec>>,
    cancellations: Mutex<HashMap<String, watch::Sender<bool>>>,
    progress_events: StdMutex<HashMap<String, Instant>>,
    history: Arc<HistoryStore>,
    events: EventHub,
    recent_limit_per_direction: AtomicUsize,
}

impl TransferService {
    pub fn new(
        history: Arc<HistoryStore>,
        events: EventHub,
        recent_limit_per_direction: usize,
    ) -> Self {
        Self {
            inner: Arc::new(TransferServiceInner {
                transfers: RwLock::new(HashMap::new()),
                retry_specs: RwLock::new(HashMap::new()),
                cancellations: Mutex::new(HashMap::new()),
                progress_events: StdMutex::new(HashMap::new()),
                history,
                events,
                recent_limit_per_direction: AtomicUsize::new(recent_limit_per_direction.max(1)),
            }),
        }
    }

    pub async fn register_outgoing(&self, spec: OutgoingTransferSpec) -> Result<TransferExecution> {
        validate_spec(&spec)?;
        let transfer_id = uuid::Uuid::new_v4().to_string();
        let preview_paths = spec
            .items
            .iter()
            .filter_map(|item| match &item.payload {
                OutgoingPayload::File(path) => Some(previewable_shared_path(path)),
                OutgoingPayload::Text(_) => None,
            })
            .collect();
        let preview_text = spec.items.iter().find_map(|item| match &item.payload {
            OutgoingPayload::Text(text) => Some(text.chars().take(4_096).collect()),
            OutgoingPayload::File(_) => None,
        });
        let record = HistoryRecord {
            id: transfer_id.clone(),
            direction: TransferDirection::Outgoing,
            source: spec.source.clone(),
            peer_id: spec.target_id.clone(),
            peer_alias: spec.peer_alias.clone(),
            peer_fingerprint: spec.peer_fingerprint.clone(),
            files: spec
                .items
                .iter()
                .map(|item| HistoryFile {
                    id: item.id.clone(),
                    name: item.name.clone(),
                    mime_type: item.mime_type.clone(),
                    size: item.size,
                    transferred_bytes: 0,
                    status: FileTransferStatus::Queued,
                })
                .collect(),
            total_bytes: spec.items.iter().map(|item| item.size).sum(),
            transferred_bytes: 0,
            status: TransferStatus::Queued,
            started_at_ms: now_ms(),
            ended_at_ms: None,
            saved_paths: Vec::new(),
            preview_paths,
            preview_text,
            error_code: None,
            error_message: None,
            retryable: false,
        };
        let (cancel_tx, cancel_rx) = watch::channel(false);
        self.inner
            .transfers
            .write()
            .await
            .insert(transfer_id.clone(), record.clone());
        self.inner
            .retry_specs
            .write()
            .await
            .insert(transfer_id.clone(), spec.clone());
        self.inner
            .cancellations
            .lock()
            .await
            .insert(transfer_id.clone(), cancel_tx);
        self.publish("transfer_changed", &record)?;

        Ok(TransferExecution {
            transfer_id,
            spec,
            cancel: cancel_rx,
        })
    }

    pub async fn register_incoming(&self, spec: IncomingTransferSpec) -> Result<HistoryRecord> {
        validate_incoming_spec(&spec)?;
        let record = HistoryRecord {
            id: spec.id.clone(),
            direction: TransferDirection::Incoming,
            source: TransferSource::RemotePeer,
            peer_id: spec.peer_id,
            peer_alias: spec.peer_alias,
            peer_fingerprint: spec.peer_fingerprint,
            files: spec
                .items
                .iter()
                .map(|item| HistoryFile {
                    id: item.id.clone(),
                    name: item.name.clone(),
                    mime_type: item.mime_type.clone(),
                    size: item.size,
                    transferred_bytes: 0,
                    status: FileTransferStatus::Queued,
                })
                .collect(),
            total_bytes: spec.items.iter().map(|item| item.size).sum(),
            transferred_bytes: 0,
            status: TransferStatus::AwaitingAcceptance,
            started_at_ms: now_ms(),
            ended_at_ms: None,
            saved_paths: Vec::new(),
            preview_paths: Vec::new(),
            preview_text: None,
            error_code: None,
            error_message: None,
            retryable: false,
        };
        let mut transfers = self.inner.transfers.write().await;
        if transfers.contains_key(&record.id) {
            return Err(anyhow!("transfer already exists: {}", record.id));
        }
        transfers.insert(record.id.clone(), record.clone());
        drop(transfers);
        self.publish("transfer_changed", &record)?;
        Ok(record)
    }

    pub async fn list(&self) -> Vec<HistoryRecord> {
        let mut records = self
            .inner
            .transfers
            .read()
            .await
            .values()
            .cloned()
            .collect::<Vec<_>>();
        records.sort_by_key(|record| std::cmp::Reverse(record.started_at_ms));
        records
    }

    pub async fn get(&self, transfer_id: &str) -> Option<HistoryRecord> {
        self.inner.transfers.read().await.get(transfer_id).cloned()
    }

    pub async fn forget_terminal(&self, transfer_id: &str) -> bool {
        let removed = {
            let mut transfers = self.inner.transfers.write().await;
            if transfers
                .get(transfer_id)
                .is_some_and(|record| record.status.is_terminal())
            {
                transfers.remove(transfer_id);
                true
            } else {
                false
            }
        };
        if removed {
            self.inner.retry_specs.write().await.remove(transfer_id);
            self.inner.cancellations.lock().await.remove(transfer_id);
            if let Ok(mut events) = self.inner.progress_events.lock() {
                events.remove(transfer_id);
            }
        }
        removed
    }

    pub async fn forget_all_terminal(&self) -> usize {
        let terminal_ids = self
            .inner
            .transfers
            .read()
            .await
            .values()
            .filter(|record| record.status.is_terminal())
            .map(|record| record.id.clone())
            .collect::<Vec<_>>();
        let mut removed = 0;
        for transfer_id in terminal_ids {
            removed += usize::from(self.forget_terminal(&transfer_id).await);
        }
        removed
    }

    pub async fn forget_terminal_direction(&self, direction: &TransferDirection) -> usize {
        let terminal_ids = self
            .inner
            .transfers
            .read()
            .await
            .values()
            .filter(|record| record.status.is_terminal() && &record.direction == direction)
            .map(|record| record.id.clone())
            .collect::<Vec<_>>();
        let mut removed = 0;
        for transfer_id in terminal_ids {
            removed += usize::from(self.forget_terminal(&transfer_id).await);
        }
        removed
    }

    pub async fn transition(
        &self,
        transfer_id: &str,
        status: TransferStatus,
    ) -> Result<HistoryRecord> {
        if status.is_terminal() {
            return Err(anyhow!("terminal transitions must use a finish method"));
        }
        let record = {
            let mut transfers = self.inner.transfers.write().await;
            let record = transfers
                .get_mut(transfer_id)
                .ok_or_else(|| anyhow!("transfer not found: {transfer_id}"))?;
            if record.status.is_terminal() {
                return Err(anyhow!("transfer is already terminal: {transfer_id}"));
            }
            record.status = status;
            for file in &mut record.files {
                if matches!(file.status, FileTransferStatus::Queued) {
                    file.status = FileTransferStatus::Transferring;
                }
            }
            record.clone()
        };
        self.publish("transfer_changed", &record)?;
        Ok(record)
    }

    pub async fn set_file_progress(
        &self,
        transfer_id: &str,
        file_id: &str,
        transferred_bytes: u64,
    ) -> Result<HistoryRecord> {
        let record = {
            let mut transfers = self.inner.transfers.write().await;
            let record = transfers
                .get_mut(transfer_id)
                .ok_or_else(|| anyhow!("transfer not found: {transfer_id}"))?;
            if record.status.is_terminal() {
                return Err(anyhow!("transfer is already terminal: {transfer_id}"));
            }
            let file = record
                .files
                .iter_mut()
                .find(|file| file.id == file_id)
                .ok_or_else(|| anyhow!("transfer file not found: {file_id}"))?;
            file.transferred_bytes = file.transferred_bytes.max(transferred_bytes.min(file.size));
            file.status = if file.transferred_bytes == file.size {
                FileTransferStatus::Completed
            } else {
                FileTransferStatus::Transferring
            };
            record.transferred_bytes = record.files.iter().map(|file| file.transferred_bytes).sum();
            record.status = TransferStatus::Transferring;
            record.clone()
        };

        if self.should_publish_progress(transfer_id, &record) {
            self.publish("transfer_progress", &record)?;
        }
        Ok(record)
    }

    pub async fn request_cancel(&self, transfer_id: &str) -> Result<bool> {
        let cancellations = self.inner.cancellations.lock().await;
        let Some(sender) = cancellations.get(transfer_id) else {
            return Ok(false);
        };
        sender
            .send(true)
            .map_err(|_| anyhow!("transfer task is no longer running: {transfer_id}"))?;
        Ok(true)
    }

    pub async fn retry_spec(&self, transfer_id: &str) -> Option<OutgoingTransferSpec> {
        self.inner
            .retry_specs
            .read()
            .await
            .get(transfer_id)
            .cloned()
    }

    pub async fn finish_completed(&self, transfer_id: &str) -> Result<HistoryRecord> {
        self.finish_terminal(
            transfer_id,
            TerminalOutcome {
                status: TransferStatus::Completed,
                error_code: None,
                error_message: None,
                retryable: false,
                saved_paths: None,
                preview_text: None,
            },
        )
        .await
    }

    pub async fn finish_completed_with_content(
        &self,
        transfer_id: &str,
        saved_paths: Vec<String>,
        preview_text: Option<String>,
    ) -> Result<HistoryRecord> {
        self.finish_terminal(
            transfer_id,
            TerminalOutcome {
                status: TransferStatus::Completed,
                error_code: None,
                error_message: None,
                retryable: false,
                saved_paths: Some(saved_paths),
                preview_text,
            },
        )
        .await
    }

    pub async fn finish_cancelled(&self, transfer_id: &str) -> Result<HistoryRecord> {
        self.finish_terminal(
            transfer_id,
            TerminalOutcome {
                status: TransferStatus::Cancelled,
                error_code: Some("cancelled"),
                error_message: Some("Transfer cancelled"),
                retryable: true,
                saved_paths: None,
                preview_text: None,
            },
        )
        .await
    }

    pub async fn finish_incoming_cancelled(&self, transfer_id: &str) -> Result<HistoryRecord> {
        self.finish_terminal(
            transfer_id,
            TerminalOutcome {
                status: TransferStatus::Cancelled,
                error_code: Some("sender_cancelled"),
                error_message: Some("Sender cancelled the transfer"),
                retryable: false,
                saved_paths: None,
                preview_text: None,
            },
        )
        .await
    }

    pub async fn finish_declined(
        &self,
        transfer_id: &str,
        error_code: &str,
        error_message: &str,
    ) -> Result<HistoryRecord> {
        self.finish_terminal(
            transfer_id,
            TerminalOutcome {
                status: TransferStatus::Declined,
                error_code: Some(error_code),
                error_message: Some(error_message),
                retryable: false,
                saved_paths: None,
                preview_text: None,
            },
        )
        .await
    }

    pub async fn finish_failed(
        &self,
        transfer_id: &str,
        error_code: &str,
        error_message: &str,
        retryable: bool,
    ) -> Result<HistoryRecord> {
        self.finish_terminal(
            transfer_id,
            TerminalOutcome {
                status: TransferStatus::Failed,
                error_code: Some(error_code),
                error_message: Some(error_message),
                retryable,
                saved_paths: None,
                preview_text: None,
            },
        )
        .await
    }

    #[cfg(test)]
    pub fn history(&self) -> &Arc<HistoryStore> {
        &self.inner.history
    }

    async fn finish_terminal(
        &self,
        transfer_id: &str,
        outcome: TerminalOutcome<'_>,
    ) -> Result<HistoryRecord> {
        let TerminalOutcome {
            status,
            error_code,
            error_message,
            retryable,
            saved_paths,
            preview_text,
        } = outcome;
        let record = {
            let mut transfers = self.inner.transfers.write().await;
            let record = transfers
                .get_mut(transfer_id)
                .ok_or_else(|| anyhow!("transfer not found: {transfer_id}"))?;
            if record.status.is_terminal() {
                return Ok(record.clone());
            }
            record.status = status.clone();
            record.ended_at_ms = Some(now_ms());
            record.error_code = error_code.map(str::to_string);
            record.error_message = error_message.map(str::to_string);
            record.retryable = retryable;
            if let Some(saved_paths) = saved_paths {
                record.saved_paths = saved_paths.clone();
                record.preview_paths = saved_paths;
            }
            if preview_text.is_some() {
                record.preview_text = preview_text;
            }
            for file in &mut record.files {
                match status {
                    TransferStatus::Completed => {
                        file.transferred_bytes = file.size;
                        file.status = FileTransferStatus::Completed;
                    }
                    TransferStatus::Cancelled | TransferStatus::Declined
                        if !matches!(file.status, FileTransferStatus::Completed) =>
                    {
                        file.status = FileTransferStatus::Cancelled;
                    }
                    TransferStatus::Failed
                        if !matches!(file.status, FileTransferStatus::Completed) =>
                    {
                        file.status = FileTransferStatus::Failed;
                    }
                    _ => {}
                }
            }
            record.transferred_bytes = record.files.iter().map(|file| file.transferred_bytes).sum();
            record.clone()
        };
        self.inner.history.insert(&record)?;
        self.inner.cancellations.lock().await.remove(transfer_id);
        self.inner
            .progress_events
            .lock()
            .map_err(|_| anyhow!("progress event lock poisoned"))?
            .remove(transfer_id);
        self.publish("transfer_changed", &record)?;
        self.prune_recent().await;
        Ok(record)
    }

    fn should_publish_progress(&self, transfer_id: &str, record: &HistoryRecord) -> bool {
        let now = Instant::now();
        let Ok(mut events) = self.inner.progress_events.lock() else {
            return true;
        };
        let should_publish = record.transferred_bytes == record.total_bytes
            || events
                .get(transfer_id)
                .map(|last| now.duration_since(*last) >= Duration::from_millis(100))
                .unwrap_or(true);
        if should_publish {
            events.insert(transfer_id.to_string(), now);
        }
        should_publish
    }

    fn publish(&self, event: &str, record: &HistoryRecord) -> Result<()> {
        self.inner
            .events
            .publish(event, serde_json::to_value(record)?);
        Ok(())
    }

    async fn prune_recent(&self) {
        let removed_ids = {
            let mut transfers = self.inner.transfers.write().await;
            let limit = self
                .inner
                .recent_limit_per_direction
                .load(Ordering::Relaxed);
            let mut removed = Vec::new();
            for direction in [TransferDirection::Outgoing, TransferDirection::Incoming] {
                let mut terminal = transfers
                    .values()
                    .filter(|record| record.status.is_terminal() && record.direction == direction)
                    .map(|record| (record.started_at_ms, record.id.clone()))
                    .collect::<Vec<_>>();
                terminal.sort_by_key(|(started_at_ms, _)| *started_at_ms);
                let remove_count = terminal.len().saturating_sub(limit);
                for (_, transfer_id) in terminal.into_iter().take(remove_count) {
                    transfers.remove(&transfer_id);
                    removed.push(transfer_id);
                }
            }
            removed
        };
        if !removed_ids.is_empty() {
            let mut retry_specs = self.inner.retry_specs.write().await;
            for transfer_id in removed_ids {
                retry_specs.remove(&transfer_id);
            }
        }
    }

    pub async fn set_recent_limit_per_direction(&self, limit: usize) {
        self.inner
            .recent_limit_per_direction
            .store(limit.max(1), Ordering::Relaxed);
        self.prune_recent().await;
    }
}

fn previewable_shared_path(path: &std::path::Path) -> String {
    let path = path.to_string_lossy();
    if let Some(suffix) = path.strip_prefix("/data/media/0") {
        format!("/sdcard{suffix}")
    } else if let Some(suffix) = path.strip_prefix("/storage/emulated/0") {
        format!("/sdcard{suffix}")
    } else {
        path.into_owned()
    }
}

fn validate_spec(spec: &OutgoingTransferSpec) -> Result<()> {
    if spec.target_id.trim().is_empty() {
        return Err(anyhow!("target id must not be empty"));
    }
    if spec.items.is_empty() {
        return Err(anyhow!("transfer must contain at least one item"));
    }
    let mut ids = HashSet::new();
    for item in &spec.items {
        if item.id.trim().is_empty() || !ids.insert(item.id.clone()) {
            return Err(anyhow!("transfer item ids must be unique and non-empty"));
        }
        if item.name.trim().is_empty() {
            return Err(anyhow!("transfer item name must not be empty"));
        }
    }
    Ok(())
}

fn validate_incoming_spec(spec: &IncomingTransferSpec) -> Result<()> {
    if spec.id.trim().is_empty() {
        return Err(anyhow!("incoming transfer id must not be empty"));
    }
    if spec.peer_id.trim().is_empty() || spec.peer_alias.trim().is_empty() {
        return Err(anyhow!("incoming peer identity must not be empty"));
    }
    if spec.items.is_empty() {
        return Err(anyhow!("incoming transfer must contain at least one item"));
    }
    let mut ids = HashSet::new();
    for item in &spec.items {
        if item.id.trim().is_empty() || !ids.insert(item.id.clone()) {
            return Err(anyhow!("incoming item ids must be unique and non-empty"));
        }
        if item.name.trim().is_empty() {
            return Err(anyhow!("incoming item name must not be empty"));
        }
    }
    Ok(())
}

fn now_ms() -> i64 {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    i64::try_from(millis).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{TransferSource, TransferStatus};
    use crate::events::EventHub;
    use crate::history::HistoryStore;
    use std::sync::Arc;

    fn harness() -> (TransferService, tempfile::TempDir) {
        let temp = tempfile::tempdir().unwrap();
        let history = Arc::new(HistoryStore::open(temp.path().join("history.db"), 20).unwrap());
        (TransferService::new(history, EventHub::new(32), 20), temp)
    }

    fn spec() -> OutgoingTransferSpec {
        OutgoingTransferSpec {
            target_id: "peer-1".to_string(),
            peer_alias: "Desktop".to_string(),
            peer_fingerprint: Some("aa11".to_string()),
            source: TransferSource::AppPicker,
            items: vec![OutgoingItemSpec {
                id: "file-1".to_string(),
                name: "file.txt".to_string(),
                mime_type: "text/plain".to_string(),
                size: 100,
                payload: OutgoingPayload::Text("hello".to_string()),
            }],
        }
    }

    #[tokio::test]
    async fn progress_is_monotonic_and_terminal_record_is_persisted() {
        let (service, _temp) = harness();
        let execution = service.register_outgoing(spec()).await.unwrap();

        service
            .transition(&execution.transfer_id, TransferStatus::Transferring)
            .await
            .unwrap();
        service
            .set_file_progress(&execution.transfer_id, "file-1", 40)
            .await
            .unwrap();
        service
            .set_file_progress(&execution.transfer_id, "file-1", 20)
            .await
            .unwrap();

        assert_eq!(
            service
                .get(&execution.transfer_id)
                .await
                .unwrap()
                .transferred_bytes,
            40
        );

        service
            .finish_completed(&execution.transfer_id)
            .await
            .unwrap();
        let record = service.get(&execution.transfer_id).await.unwrap();
        assert_eq!(record.status, TransferStatus::Completed);
        assert_eq!(record.transferred_bytes, 100);
        assert_eq!(record.preview_text.as_deref(), Some("hello"));
        assert_eq!(service.history().list(10).unwrap().len(), 1);
    }

    #[tokio::test]
    async fn cancel_notifies_running_execution_and_reaches_terminal_state() {
        let (service, _temp) = harness();
        let mut execution = service.register_outgoing(spec()).await.unwrap();

        assert!(service
            .request_cancel(&execution.transfer_id)
            .await
            .unwrap());
        execution.cancel.changed().await.unwrap();
        assert!(*execution.cancel.borrow());

        service
            .finish_cancelled(&execution.transfer_id)
            .await
            .unwrap();
        assert_eq!(
            service.get(&execution.transfer_id).await.unwrap().status,
            TransferStatus::Cancelled
        );
    }

    #[tokio::test]
    async fn retry_spec_survives_a_retryable_failure() {
        let (service, _temp) = harness();
        let execution = service.register_outgoing(spec()).await.unwrap();

        service
            .finish_failed(
                &execution.transfer_id,
                "target_offline",
                "Target is offline",
                true,
            )
            .await
            .unwrap();

        let retry = service.retry_spec(&execution.transfer_id).await.unwrap();
        assert_eq!(retry.target_id, "peer-1");
        assert_eq!(retry.items.len(), 1);
    }

    #[tokio::test]
    async fn incoming_transfer_persists_saved_paths_after_completion() {
        let (service, _temp) = harness();
        let transfer_id = "incoming-1";
        service
            .register_incoming(IncomingTransferSpec {
                id: transfer_id.to_string(),
                peer_id: "peer-1".to_string(),
                peer_alias: "Desktop".to_string(),
                peer_fingerprint: Some("aa11".to_string()),
                items: vec![IncomingItemSpec {
                    id: "file-1".to_string(),
                    name: "photo.jpg".to_string(),
                    mime_type: "image/jpeg".to_string(),
                    size: 100,
                }],
            })
            .await
            .unwrap();
        service
            .transition(transfer_id, TransferStatus::Transferring)
            .await
            .unwrap();
        service
            .set_file_progress(transfer_id, "file-1", 100)
            .await
            .unwrap();

        let record = service
            .finish_completed_with_content(
                transfer_id,
                vec!["/sdcard/Pictures/AirSend/photo.jpg".to_string()],
                None,
            )
            .await
            .unwrap();

        assert_eq!(record.direction, TransferDirection::Incoming);
        assert_eq!(record.status, TransferStatus::Completed);
        assert_eq!(
            record.saved_paths,
            vec!["/sdcard/Pictures/AirSend/photo.jpg"]
        );
        assert_eq!(
            record.preview_paths,
            vec!["/sdcard/Pictures/AirSend/photo.jpg"]
        );
        assert_eq!(service.history().list(10).unwrap(), vec![record]);
    }

    #[tokio::test]
    async fn incoming_clipboard_persists_text_preview_after_completion() {
        let (service, _temp) = harness();
        let transfer_id = "incoming-clipboard";
        service
            .register_incoming(IncomingTransferSpec {
                id: transfer_id.to_string(),
                peer_id: "peer-1".to_string(),
                peer_alias: "Desktop".to_string(),
                peer_fingerprint: Some("aa11".to_string()),
                items: vec![IncomingItemSpec {
                    id: "text-1".to_string(),
                    name: "clipboard.txt".to_string(),
                    mime_type: "text/plain".to_string(),
                    size: 5,
                }],
            })
            .await
            .unwrap();

        let record = service
            .finish_completed_with_content(transfer_id, Vec::new(), Some("hello".to_string()))
            .await
            .unwrap();

        assert_eq!(record.preview_text.as_deref(), Some("hello"));
        assert!(record.preview_paths.is_empty());
        assert_eq!(service.history().list(10).unwrap(), vec![record]);
    }

    #[tokio::test]
    async fn outgoing_root_path_is_exposed_as_shared_storage_preview() {
        let (service, _temp) = harness();
        let mut outgoing = spec();
        outgoing.items[0].payload = OutgoingPayload::File(PathBuf::from(
            "/data/media/0/Pictures/Screenshots/example.jpg",
        ));
        outgoing.items[0].name = "example.jpg".to_string();
        outgoing.items[0].mime_type = "image/jpeg".to_string();

        let execution = service.register_outgoing(outgoing).await.unwrap();
        let record = service.get(&execution.transfer_id).await.unwrap();

        assert_eq!(
            record.preview_paths,
            vec!["/sdcard/Pictures/Screenshots/example.jpg"]
        );
        assert_eq!(record.preview_text, None);
    }

    #[tokio::test]
    async fn declined_incoming_transfer_is_terminal_history() {
        let (service, _temp) = harness();
        service
            .register_incoming(IncomingTransferSpec {
                id: "incoming-2".to_string(),
                peer_id: "peer-2".to_string(),
                peer_alias: "Untrusted".to_string(),
                peer_fingerprint: Some("bb22".to_string()),
                items: vec![IncomingItemSpec {
                    id: "file-2".to_string(),
                    name: "file.bin".to_string(),
                    mime_type: "application/octet-stream".to_string(),
                    size: 10,
                }],
            })
            .await
            .unwrap();

        let record = service
            .finish_declined("incoming-2", "untrusted_peer", "Peer is not trusted")
            .await
            .unwrap();

        assert_eq!(record.status, TransferStatus::Declined);
        assert_eq!(record.error_code.as_deref(), Some("untrusted_peer"));
        assert_eq!(service.history().list(10).unwrap(), vec![record]);
    }
}
