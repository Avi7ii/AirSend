use crate::domain::{HistoryFile, HistoryRecord, TransferDirection};
use anyhow::{anyhow, Context, Result};
use rusqlite::{params, Connection};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Duration;

pub const SCHEMA_VERSION: i64 = 2;

#[derive(Debug)]
pub struct HistoryStore {
    connection: Mutex<Connection>,
    retention_limit_per_direction: AtomicUsize,
}

impl HistoryStore {
    pub fn open(path: impl AsRef<Path>, retention_limit_per_direction: usize) -> Result<Self> {
        if retention_limit_per_direction == 0 {
            return Err(anyhow!("history retention limit must be greater than zero"));
        }
        let path = path.as_ref();
        let parent = path
            .parent()
            .ok_or_else(|| anyhow!("history path has no parent: {}", path.display()))?;
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;

        let connection =
            Connection::open(path).with_context(|| format!("failed to open {}", path.display()))?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = FULL;
             PRAGMA foreign_keys = ON;
             CREATE TABLE IF NOT EXISTS transfer_history (
                 id TEXT PRIMARY KEY NOT NULL,
                 direction TEXT NOT NULL,
                 source TEXT NOT NULL,
                 peer_id TEXT NOT NULL,
                 peer_alias TEXT NOT NULL,
                 peer_fingerprint TEXT,
                 files_json TEXT NOT NULL,
                 total_bytes INTEGER NOT NULL,
                 transferred_bytes INTEGER NOT NULL,
                 status TEXT NOT NULL,
                 started_at_ms INTEGER NOT NULL,
                 ended_at_ms INTEGER,
                 saved_paths_json TEXT NOT NULL,
                 error_code TEXT,
                 error_message TEXT,
                 retryable INTEGER NOT NULL,
                 preview_paths_json TEXT NOT NULL DEFAULT '[]',
                 preview_text TEXT
             );
             CREATE INDEX IF NOT EXISTS transfer_history_started_idx
                 ON transfer_history(started_at_ms DESC);",
        )?;
        ensure_column(
            &connection,
            "transfer_history",
            "preview_paths_json",
            "TEXT NOT NULL DEFAULT '[]'",
        )?;
        ensure_column(&connection, "transfer_history", "preview_text", "TEXT")?;
        connection.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        set_sidecar_permissions(path);

        let store = Self {
            connection: Mutex::new(connection),
            retention_limit_per_direction: AtomicUsize::new(retention_limit_per_direction),
        };
        store.remove_invalid_empty_clipboard_records()?;
        store.prune_to_limit(retention_limit_per_direction)?;
        Ok(store)
    }

    pub fn insert(&self, record: &HistoryRecord) -> Result<()> {
        if !record.status.is_terminal() || record.ended_at_ms.is_none() {
            return Err(anyhow!("only terminal transfer records can be persisted"));
        }

        let mut connection = self
            .connection
            .lock()
            .map_err(|_| anyhow!("history database lock poisoned"))?;
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT INTO transfer_history (
                 id, direction, source, peer_id, peer_alias, peer_fingerprint,
                 files_json, total_bytes, transferred_bytes, status,
                 started_at_ms, ended_at_ms, saved_paths_json, error_code,
                 error_message, retryable, preview_paths_json, preview_text
             ) VALUES (
                 ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                 ?14, ?15, ?16, ?17, ?18
             )
             ON CONFLICT(id) DO UPDATE SET
                 direction = excluded.direction,
                 source = excluded.source,
                 peer_id = excluded.peer_id,
                 peer_alias = excluded.peer_alias,
                 peer_fingerprint = excluded.peer_fingerprint,
                 files_json = excluded.files_json,
                 total_bytes = excluded.total_bytes,
                 transferred_bytes = excluded.transferred_bytes,
                 status = excluded.status,
                 started_at_ms = excluded.started_at_ms,
                 ended_at_ms = excluded.ended_at_ms,
                 saved_paths_json = excluded.saved_paths_json,
                 error_code = excluded.error_code,
                 error_message = excluded.error_message,
                 retryable = excluded.retryable,
                 preview_paths_json = excluded.preview_paths_json,
                 preview_text = excluded.preview_text",
            params![
                record.id,
                encode(&record.direction)?,
                encode(&record.source)?,
                record.peer_id,
                record.peer_alias,
                record.peer_fingerprint,
                encode(&record.files)?,
                to_i64(record.total_bytes, "total_bytes")?,
                to_i64(record.transferred_bytes, "transferred_bytes")?,
                encode(&record.status)?,
                record.started_at_ms,
                record.ended_at_ms,
                encode(&record.saved_paths)?,
                record.error_code,
                record.error_message,
                i64::from(record.retryable),
                encode(&record.preview_paths)?,
                record.preview_text,
            ],
        )?;
        prune_transaction(
            &transaction,
            self.retention_limit_per_direction.load(Ordering::Relaxed),
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn list(&self, limit: usize) -> Result<Vec<HistoryRecord>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let connection = self
            .connection
            .lock()
            .map_err(|_| anyhow!("history database lock poisoned"))?;
        let mut statement = connection.prepare(
            "SELECT id, direction, source, peer_id, peer_alias,
                    peer_fingerprint, files_json, total_bytes,
                    transferred_bytes, status, started_at_ms, ended_at_ms,
                    saved_paths_json, error_code, error_message, retryable,
                    preview_paths_json, preview_text
             FROM transfer_history
             ORDER BY started_at_ms DESC, id DESC
             LIMIT ?1",
        )?;
        let rows = statement
            .query_map(
                [limit.min(
                    self.retention_limit_per_direction
                        .load(Ordering::Relaxed)
                        .saturating_mul(2),
                ) as i64],
                RawHistoryRecord::from_row,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows.into_iter().map(RawHistoryRecord::decode).collect()
    }

    pub fn delete(&self, id: &str) -> Result<bool> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| anyhow!("history database lock poisoned"))?;
        Ok(connection.execute("DELETE FROM transfer_history WHERE id = ?1", [id])? > 0)
    }

    pub fn clear(&self) -> Result<usize> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| anyhow!("history database lock poisoned"))?;
        Ok(connection.execute("DELETE FROM transfer_history", [])?)
    }

    pub fn clear_direction(&self, direction: &TransferDirection) -> Result<usize> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| anyhow!("history database lock poisoned"))?;
        Ok(connection.execute(
            "DELETE FROM transfer_history WHERE direction = ?1",
            [encode(direction)?],
        )?)
    }

    pub fn set_retention_limit_per_direction(&self, limit: usize) -> Result<usize> {
        if limit == 0 {
            return Err(anyhow!("history retention limit must be greater than zero"));
        }
        let deleted = self.prune_to_limit(limit)?;
        self.retention_limit_per_direction
            .store(limit, Ordering::Relaxed);
        Ok(deleted)
    }

    fn prune_to_limit(&self, limit: usize) -> Result<usize> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| anyhow!("history database lock poisoned"))?;
        let transaction = connection.transaction()?;
        let deleted = prune_transaction(&transaction, limit)?;
        transaction.commit()?;
        Ok(deleted)
    }

    fn remove_invalid_empty_clipboard_records(&self) -> Result<usize> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| anyhow!("history database lock poisoned"))?;
        let candidates = {
            let mut statement = connection.prepare(
                "SELECT id, files_json
                 FROM transfer_history
                 WHERE total_bytes = 0",
            )?;
            let rows = statement
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };
        let invalid_ids = candidates
            .into_iter()
            .filter_map(|(id, files_json)| {
                let files = decode::<Vec<HistoryFile>>(&files_json).ok()?;
                is_invalid_empty_clipboard_history(&files).then_some(id)
            })
            .collect::<Vec<_>>();
        if invalid_ids.is_empty() {
            return Ok(0);
        }

        let transaction = connection.transaction()?;
        let mut deleted = 0;
        for id in invalid_ids {
            deleted += transaction.execute("DELETE FROM transfer_history WHERE id = ?1", [id])?;
        }
        transaction.commit()?;
        Ok(deleted)
    }
}

fn is_invalid_empty_clipboard_history(files: &[HistoryFile]) -> bool {
    files.len() == 1
        && files[0].size == 0
        && files[0].name.eq_ignore_ascii_case("clipboard.txt")
        && files[0].mime_type.eq_ignore_ascii_case("text/plain")
}

struct RawHistoryRecord {
    id: String,
    direction: String,
    source: String,
    peer_id: String,
    peer_alias: String,
    peer_fingerprint: Option<String>,
    files: String,
    total_bytes: i64,
    transferred_bytes: i64,
    status: String,
    started_at_ms: i64,
    ended_at_ms: Option<i64>,
    saved_paths: String,
    error_code: Option<String>,
    error_message: Option<String>,
    retryable: bool,
    preview_paths: String,
    preview_text: Option<String>,
}

impl RawHistoryRecord {
    fn from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            direction: row.get(1)?,
            source: row.get(2)?,
            peer_id: row.get(3)?,
            peer_alias: row.get(4)?,
            peer_fingerprint: row.get(5)?,
            files: row.get(6)?,
            total_bytes: row.get(7)?,
            transferred_bytes: row.get(8)?,
            status: row.get(9)?,
            started_at_ms: row.get(10)?,
            ended_at_ms: row.get(11)?,
            saved_paths: row.get(12)?,
            error_code: row.get(13)?,
            error_message: row.get(14)?,
            retryable: row.get(15)?,
            preview_paths: row.get(16)?,
            preview_text: row.get(17)?,
        })
    }

    fn decode(self) -> Result<HistoryRecord> {
        Ok(HistoryRecord {
            id: self.id,
            direction: decode(&self.direction)?,
            source: decode(&self.source)?,
            peer_id: self.peer_id,
            peer_alias: self.peer_alias,
            peer_fingerprint: self.peer_fingerprint,
            files: decode::<Vec<HistoryFile>>(&self.files)?,
            total_bytes: to_u64(self.total_bytes, "total_bytes")?,
            transferred_bytes: to_u64(self.transferred_bytes, "transferred_bytes")?,
            status: decode(&self.status)?,
            started_at_ms: self.started_at_ms,
            ended_at_ms: self.ended_at_ms,
            saved_paths: decode::<Vec<String>>(&self.saved_paths)?,
            preview_paths: decode::<Vec<String>>(&self.preview_paths)?,
            preview_text: self.preview_text,
            error_code: self.error_code,
            error_message: self.error_message,
            retryable: self.retryable,
        })
    }
}

fn ensure_column(
    connection: &Connection,
    table: &str,
    column: &str,
    declaration: &str,
) -> Result<()> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !columns.iter().any(|value| value == column) {
        connection.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {declaration}"
        ))?;
    }
    Ok(())
}

fn prune_transaction(transaction: &rusqlite::Transaction<'_>, limit: usize) -> Result<usize> {
    let limit = i64::try_from(limit).context("history retention limit is too large")?;
    let mut deleted = 0;
    for direction in [TransferDirection::Outgoing, TransferDirection::Incoming] {
        deleted += transaction.execute(
            "DELETE FROM transfer_history
             WHERE id IN (
                 SELECT id FROM transfer_history
                 WHERE direction = ?1
                 ORDER BY started_at_ms DESC, id DESC
                 LIMIT -1 OFFSET ?2
             )",
            params![encode(&direction)?, limit],
        )?;
    }
    Ok(deleted)
}

fn encode<T: serde::Serialize>(value: &T) -> Result<String> {
    serde_json::to_string(value).context("failed to encode history field")
}

fn decode<T: serde::de::DeserializeOwned>(value: &str) -> Result<T> {
    serde_json::from_str(value).context("failed to decode history field")
}

fn to_i64(value: u64, field: &str) -> Result<i64> {
    i64::try_from(value).with_context(|| format!("{field} exceeds SQLite integer range"))
}

fn to_u64(value: i64, field: &str) -> Result<u64> {
    u64::try_from(value).with_context(|| format!("{field} is negative"))
}

fn set_sidecar_permissions(path: &Path) {
    for suffix in ["-wal", "-shm"] {
        let sidecar = PathBuf::from(format!("{}{suffix}", path.display()));
        if sidecar.exists() {
            let _ = fs::set_permissions(sidecar, fs::Permissions::from_mode(0o600));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{FileTransferStatus, HistoryRecord, TransferSource, TransferStatus};

    #[test]
    fn inserts_queries_deletes_and_caps_history() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("history.db");
        let store = HistoryStore::open(&path, 3).unwrap();
        for index in 0..5 {
            store
                .insert(&HistoryRecord::completed_for_test(index))
                .unwrap();
        }

        let records = store.list(20).unwrap();

        assert_eq!(records.len(), 3);
        assert!(records[0].started_at_ms > records[1].started_at_ms);
        assert!(store.delete(&records[0].id).unwrap());
        assert_eq!(store.list(20).unwrap().len(), 2);
        assert_eq!(store.clear().unwrap(), 2);
        assert!(store.list(20).unwrap().is_empty());
    }

    #[test]
    fn rejects_non_terminal_records() {
        let temp = tempfile::tempdir().unwrap();
        let store = HistoryStore::open(temp.path().join("history.db"), 10).unwrap();
        let mut record = HistoryRecord::completed_for_test(1);
        record.status = TransferStatus::Transferring;
        record.ended_at_ms = None;

        let error = store.insert(&record).unwrap_err();

        assert!(error.to_string().contains("terminal"));
    }

    #[test]
    fn records_survive_reopening_database() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("history.db");
        let record = HistoryRecord::completed_for_test(9);
        HistoryStore::open(&path, 10)
            .unwrap()
            .insert(&record)
            .unwrap();

        let records = HistoryStore::open(path, 10).unwrap().list(10).unwrap();

        assert_eq!(records, vec![record]);
    }

    #[test]
    fn removes_only_invalid_empty_clipboard_records_when_reopening() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("history.db");
        let store = HistoryStore::open(&path, 10).unwrap();

        let mut empty_clipboard = HistoryRecord::completed_for_test(1);
        empty_clipboard.id = "empty-clipboard".to_string();
        empty_clipboard.direction = TransferDirection::Incoming;
        empty_clipboard.source = TransferSource::RemotePeer;
        empty_clipboard.files = vec![HistoryFile {
            id: "clipboard".to_string(),
            name: "clipboard.txt".to_string(),
            mime_type: "text/plain".to_string(),
            size: 0,
            transferred_bytes: 0,
            status: FileTransferStatus::Completed,
        }];
        empty_clipboard.total_bytes = 0;
        empty_clipboard.transferred_bytes = 0;
        empty_clipboard.preview_text = Some(String::new());
        store.insert(&empty_clipboard).unwrap();

        let mut empty_file = empty_clipboard.clone();
        empty_file.id = "empty-file".to_string();
        empty_file.files[0].name = "empty.txt".to_string();
        empty_file.preview_text = None;
        store.insert(&empty_file).unwrap();
        drop(store);

        let records = HistoryStore::open(path, 10).unwrap().list(10).unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].id, "empty-file");
    }

    #[test]
    fn caps_incoming_and_outgoing_history_independently() {
        let temp = tempfile::tempdir().unwrap();
        let store = HistoryStore::open(temp.path().join("history.db"), 3).unwrap();
        for index in 0..5 {
            store
                .insert(&HistoryRecord::completed_for_test(index))
                .unwrap();
            let mut incoming = HistoryRecord::completed_for_test(index + 10);
            incoming.id = format!("incoming-{index}");
            incoming.direction = TransferDirection::Incoming;
            store.insert(&incoming).unwrap();
        }

        let records = store.list(20).unwrap();

        assert_eq!(records.len(), 6);
        assert_eq!(
            records
                .iter()
                .filter(|record| record.direction == TransferDirection::Outgoing)
                .count(),
            3
        );
        assert_eq!(
            records
                .iter()
                .filter(|record| record.direction == TransferDirection::Incoming)
                .count(),
            3
        );
        assert_eq!(store.set_retention_limit_per_direction(2).unwrap(), 2);
        assert_eq!(store.list(20).unwrap().len(), 4);
    }

    #[test]
    fn clears_only_the_requested_history_direction() {
        let temp = tempfile::tempdir().unwrap();
        let store = HistoryStore::open(temp.path().join("history.db"), 10).unwrap();
        let outgoing = HistoryRecord::completed_for_test(1);
        let mut incoming = HistoryRecord::completed_for_test(2);
        incoming.id = "incoming".to_string();
        incoming.direction = TransferDirection::Incoming;
        store.insert(&outgoing).unwrap();
        store.insert(&incoming).unwrap();

        assert_eq!(
            store.clear_direction(&TransferDirection::Outgoing).unwrap(),
            1
        );
        assert_eq!(store.list(10).unwrap(), vec![incoming]);
    }
}
