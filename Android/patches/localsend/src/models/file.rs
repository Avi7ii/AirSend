use crate::error::LocalSendError;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::time::SystemTime;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileMetadata {
    pub id: String,
    pub file_name: String,
    pub size: u64,
    pub file_type: String, // mime type
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<FileMetadataExt>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileMetadataExt {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accessed: Option<String>,
}

impl FileMetadata {
    pub fn from_path(path: &Path) -> crate::error::Result<Self> {
        let metadata = path.metadata()?;
        if !metadata.is_file() {
            return Err(LocalSendError::NotAFile);
        }

        let id = path.to_str().unwrap().to_string();
        let file_name = path.file_name().unwrap().to_str().unwrap().to_string();
        let size = metadata.len();

        let file_type = mime_guess::from_path(path)
            .first()
            .map(|mime| mime.to_string())
            .unwrap_or_else(|| "application/octet-stream".to_string()); // Default type if none found

        let sha256 = Some(sha256::try_digest(path)?);

        let metadata = Some(FileMetadataExt {
            modified: metadata.modified().ok().map(|t| format_datetime(t)),
            accessed: metadata.accessed().ok().map(|t| format_datetime(t)),
        });

        Ok(FileMetadata {
            id,
            file_name,
            size,
            file_type,
            sha256,
            preview: None,
            metadata,
        })
    }
}

fn format_datetime(system_time: SystemTime) -> String {
    let datetime: DateTime<Utc> = system_time.into();
    datetime.to_rfc3339()
}
