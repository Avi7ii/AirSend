#[derive(Debug, thiserror::Error)]
pub enum LocalSendError {
    #[error("IO error: {0}")]
    IOError(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    SerializationError(#[from] serde_json::Error),

    #[error("Request error: {0}")]
    RequestError(#[from] reqwest::Error),

    #[error("Async join error: {0}")]
    JoinError(#[from] tokio::task::JoinError),

    #[error("Invalid PIN")]
    InvalidPin,

    #[error("Session blocked")]
    SessionBlocked,

    #[error("Too many requests")]
    TooManyRequests,

    #[error("Not a file")]
    NotAFile,

    #[error("Peer not found")]
    PeerNotFound,

    #[error("Upload failed")]
    UploadFailed,

    #[error("Invalid token")]
    InvalidToken,

    #[error("Session inactive")]
    SessionInactive,

    #[error("Cancel Failed")]
    CancelFailed,
}

pub type Result<T> = std::result::Result<T, LocalSendError>;
