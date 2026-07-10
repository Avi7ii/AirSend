use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TransferDirection {
    Outgoing,
    Incoming,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TransferSource {
    AppPicker,
    Clipboard,
    ShareSheet,
    Screenshot,
    RemotePeer,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TransferStatus {
    Queued,
    AwaitingAcceptance,
    Preparing,
    Transferring,
    Paused,
    Completed,
    Failed,
    Cancelled,
    Declined,
}

impl TransferStatus {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Failed | Self::Cancelled | Self::Declined
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FileTransferStatus {
    Queued,
    Transferring,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HistoryFile {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub size: u64,
    pub transferred_bytes: u64,
    pub status: FileTransferStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRecord {
    pub id: String,
    pub direction: TransferDirection,
    pub source: TransferSource,
    pub peer_id: String,
    pub peer_alias: String,
    pub peer_fingerprint: Option<String>,
    pub files: Vec<HistoryFile>,
    pub total_bytes: u64,
    pub transferred_bytes: u64,
    pub status: TransferStatus,
    pub started_at_ms: i64,
    pub ended_at_ms: Option<i64>,
    pub saved_paths: Vec<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub retryable: bool,
}

#[cfg(test)]
impl HistoryRecord {
    pub fn completed_for_test(index: i64) -> Self {
        let size = 100 + index as u64;
        Self {
            id: format!("history-{index}"),
            direction: TransferDirection::Outgoing,
            source: TransferSource::AppPicker,
            peer_id: "peer-1".to_string(),
            peer_alias: "Desktop".to_string(),
            peer_fingerprint: Some("aa:bb".to_string()),
            files: vec![HistoryFile {
                id: format!("file-{index}"),
                name: format!("file-{index}.txt"),
                mime_type: "text/plain".to_string(),
                size,
                transferred_bytes: size,
                status: FileTransferStatus::Completed,
            }],
            total_bytes: size,
            transferred_bytes: size,
            status: TransferStatus::Completed,
            started_at_ms: 1_000 + index,
            ended_at_ms: Some(2_000 + index),
            saved_paths: Vec::new(),
            error_code: None,
            error_message: None,
            retryable: false,
        }
    }
}
