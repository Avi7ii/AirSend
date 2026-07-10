use crate::domain::{HistoryFile, HistoryRecord};
use anyhow::{anyhow, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

const SCHEMA_VERSION: i64 = 1;

#[derive(Debug)]
pub struct HistoryStore {
    connection: Mutex<Connection>,
    retention_limit: usize,
}

impl HistoryStore {
    pub fn open(path: impl AsRef<Path>, retention_limit: usize) -> Result<Self> {
        if retention_limit == 0 {
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
                 retryable INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS transfer_history_started_idx
                 ON transfer_history(started_at_ms DESC);",
        )?;
        connection.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        set_sidecar_permissions(path);

        Ok(Self {
            connection: Mutex::new(connection),
            retention_limit,
        })
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
                 error_message, retryable
             ) VALUES (
                 ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                 ?14, ?15, ?16
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
                 retryable = excluded.retryable",
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
            ],
        )?;
        transaction.execute(
            "DELETE FROM transfer_history
             WHERE id IN (
                 SELECT id FROM transfer_history
                 ORDER BY started_at_ms DESC, id DESC
                 LIMIT -1 OFFSET ?1
             )",
            [self.retention_limit as i64],
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
                    saved_paths_json, error_code, error_message, retryable
             FROM transfer_history
             ORDER BY started_at_ms DESC, id DESC
             LIMIT ?1",
        )?;
        let rows = statement
            .query_map(
                [limit.min(self.retention_limit) as i64],
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

    pub fn get(&self, id: &str) -> Result<Option<HistoryRecord>> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| anyhow!("history database lock poisoned"))?;
        let mut statement = connection.prepare(
            "SELECT id, direction, source, peer_id, peer_alias,
                    peer_fingerprint, files_json, total_bytes,
                    transferred_bytes, status, started_at_ms, ended_at_ms,
                    saved_paths_json, error_code, error_message, retryable
             FROM transfer_history WHERE id = ?1",
        )?;
        statement
            .query_row([id], RawHistoryRecord::from_row)
            .optional()?
            .map(RawHistoryRecord::decode)
            .transpose()
    }
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
            error_code: self.error_code,
            error_message: self.error_message,
            retryable: self.retryable,
        })
    }
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
    use crate::domain::{HistoryRecord, TransferStatus};

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
}
