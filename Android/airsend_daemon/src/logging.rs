use anyhow::{anyhow, Context, Result};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LogDecision {
    Emit,
    Suppress,
    EmitSummary { suppressed: u64 },
}

#[derive(Debug)]
struct ErrorWindow {
    last_emit: Instant,
    suppressed: u64,
}

#[derive(Debug)]
pub struct RepeatedErrorLimiter {
    window: Duration,
    errors: HashMap<String, ErrorWindow>,
}

impl RepeatedErrorLimiter {
    pub fn new(window: Duration) -> Self {
        Self {
            window,
            errors: HashMap::new(),
        }
    }

    pub fn record(&mut self, key: impl Into<String>, now: Instant) -> LogDecision {
        let key = key.into();
        let Some(entry) = self.errors.get_mut(&key) else {
            self.errors.insert(
                key,
                ErrorWindow {
                    last_emit: now,
                    suppressed: 0,
                },
            );
            return LogDecision::Emit;
        };

        if now.duration_since(entry.last_emit) < self.window {
            entry.suppressed = entry.suppressed.saturating_add(1);
            return LogDecision::Suppress;
        }

        entry.last_emit = now;
        let suppressed = std::mem::take(&mut entry.suppressed);
        if suppressed == 0 {
            LogDecision::Emit
        } else {
            LogDecision::EmitSummary { suppressed }
        }
    }

    #[cfg(test)]
    pub fn suppressed(&self, key: &str) -> u64 {
        self.errors
            .get(key)
            .map(|entry| entry.suppressed)
            .unwrap_or(0)
    }
}

#[derive(Clone)]
pub struct SizeRotatingWriter {
    inner: Arc<Mutex<WriterState>>,
}

struct WriterState {
    path: PathBuf,
    max_bytes: u64,
    backup_count: usize,
    file: Option<File>,
    active_bytes: u64,
}

impl SizeRotatingWriter {
    pub fn new(path: impl Into<PathBuf>, max_bytes: u64, backup_count: usize) -> Result<Self> {
        if max_bytes == 0 {
            return Err(anyhow!("maximum log size must be greater than zero"));
        }
        let path = path.into();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let active_bytes = fs::metadata(&path).map(|value| value.len()).unwrap_or(0);
        let mut state = WriterState {
            path,
            max_bytes,
            backup_count,
            file: None,
            active_bytes,
        };
        if state.active_bytes >= state.max_bytes {
            state.rotate()?;
        } else {
            state.open_active()?;
        }
        Ok(Self {
            inner: Arc::new(Mutex::new(state)),
        })
    }

    pub fn clear(&self) -> Result<()> {
        self.with_state(|state| {
            if let Some(file) = state.file.as_mut() {
                file.flush()?;
                file.set_len(0)?;
                file.seek(SeekFrom::Start(0))?;
            }
            state.active_bytes = 0;
            for index in 1..=state.backup_count {
                remove_if_exists(&state.backup_path(index))?;
            }
            Ok(())
        })
    }

    pub fn tail(&self, max_bytes: usize) -> Result<String> {
        self.with_state(|state| {
            if let Some(file) = state.file.as_mut() {
                file.flush()?;
            }
            let mut file = File::open(&state.path)
                .with_context(|| format!("failed to open {}", state.path.display()))?;
            let length = file.metadata()?.len();
            let start = length.saturating_sub(max_bytes as u64);
            file.seek(SeekFrom::Start(start))?;
            let mut bytes = Vec::with_capacity((length - start) as usize);
            file.read_to_end(&mut bytes)?;
            Ok(String::from_utf8_lossy(&bytes).into_owned())
        })
    }

    pub fn paths(&self) -> Result<Vec<PathBuf>> {
        self.with_state(|state| {
            let mut paths = vec![state.path.clone()];
            paths.extend((1..=state.backup_count).map(|index| state.backup_path(index)));
            Ok(paths)
        })
    }

    fn with_state<T>(&self, operation: impl FnOnce(&mut WriterState) -> Result<T>) -> Result<T> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| anyhow!("log writer lock poisoned"))?;
        operation(&mut state)
    }
}

impl Write for SizeRotatingWriter {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| std::io::Error::other("log writer lock poisoned"))?;
        state.write_all_rotating(buffer)?;
        Ok(buffer.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| std::io::Error::other("log writer lock poisoned"))?;
        if let Some(file) = state.file.as_mut() {
            file.flush()?;
        }
        Ok(())
    }
}

impl WriterState {
    fn write_all_rotating(&mut self, mut buffer: &[u8]) -> std::io::Result<()> {
        while !buffer.is_empty() {
            if self.active_bytes >= self.max_bytes {
                self.rotate().map_err(std::io::Error::other)?;
            }
            let available = (self.max_bytes - self.active_bytes) as usize;
            let chunk_length = available.min(buffer.len());
            let (chunk, remainder) = buffer.split_at(chunk_length);
            self.file
                .as_mut()
                .ok_or_else(|| std::io::Error::other("active log is not open"))?
                .write_all(chunk)?;
            self.active_bytes += chunk_length as u64;
            buffer = remainder;
        }
        Ok(())
    }

    fn rotate(&mut self) -> Result<()> {
        if let Some(mut file) = self.file.take() {
            file.flush()?;
            file.sync_data()?;
        }
        self.cap_active_to_tail()?;
        if self.backup_count > 0 {
            remove_if_exists(&self.backup_path(self.backup_count))?;
            for index in (1..self.backup_count).rev() {
                let source = self.backup_path(index);
                if source.exists() {
                    fs::rename(&source, self.backup_path(index + 1))?;
                }
            }
            if self.path.exists() {
                fs::rename(&self.path, self.backup_path(1))?;
            }
        } else {
            remove_if_exists(&self.path)?;
        }
        self.active_bytes = 0;
        self.open_active()
    }

    fn cap_active_to_tail(&mut self) -> Result<()> {
        if self.active_bytes <= self.max_bytes || !self.path.exists() {
            return Ok(());
        }

        let mut source = File::open(&self.path)
            .with_context(|| format!("failed to open {}", self.path.display()))?;
        source.seek(SeekFrom::Start(self.active_bytes - self.max_bytes))?;
        let mut tail = Vec::with_capacity(self.max_bytes as usize);
        source.read_to_end(&mut tail)?;

        let temporary_path = PathBuf::from(format!("{}.trim", self.path.display()));
        remove_if_exists(&temporary_path)?;
        let mut temporary = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temporary_path)
            .with_context(|| format!("failed to create {}", temporary_path.display()))?;
        temporary.write_all(&tail)?;
        temporary.sync_all()?;
        fs::rename(&temporary_path, &self.path)?;
        self.active_bytes = tail.len() as u64;
        Ok(())
    }

    fn open_active(&mut self) -> Result<()> {
        self.file = Some(
            OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .open(&self.path)
                .with_context(|| format!("failed to open {}", self.path.display()))?,
        );
        self.active_bytes = fs::metadata(&self.path)?.len();
        Ok(())
    }

    fn backup_path(&self, index: usize) -> PathBuf {
        PathBuf::from(format!("{}.{}", self.path.display(), index))
    }
}

fn remove_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::time::{Duration, Instant};

    #[test]
    fn rotates_existing_and_new_log_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("airsend.log");
        std::fs::write(&path, vec![b'x'; 80]).unwrap();
        let mut writer = SizeRotatingWriter::new(path.clone(), 100, 2).unwrap();

        writer.write_all(&[b'y'; 40]).unwrap();
        writer.flush().unwrap();

        assert!(path.with_extension("log.1").exists());
        assert!(std::fs::metadata(path).unwrap().len() <= 100);
    }

    #[test]
    fn rotates_oversized_existing_log_during_initialization() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("airsend.log");
        std::fs::write(&path, vec![b'x'; 250]).unwrap();

        let _writer = SizeRotatingWriter::new(path.clone(), 100, 3).unwrap();

        assert_eq!(
            std::fs::metadata(path.with_extension("log.1"))
                .unwrap()
                .len(),
            100
        );
        assert_eq!(std::fs::metadata(path).unwrap().len(), 0);
    }

    #[test]
    fn chunks_a_single_oversized_write() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("airsend.log");
        let mut writer = SizeRotatingWriter::new(path.clone(), 100, 2).unwrap();

        writer.write_all(&vec![b'z'; 250]).unwrap();
        writer.flush().unwrap();

        assert_eq!(std::fs::metadata(&path).unwrap().len(), 50);
        assert_eq!(
            std::fs::metadata(path.with_extension("log.1"))
                .unwrap()
                .len(),
            100
        );
    }

    #[test]
    fn repeated_error_is_summarized_after_window() {
        let now = Instant::now();
        let mut limiter = RepeatedErrorLimiter::new(Duration::from_secs(30));

        assert_eq!(
            limiter.record("network_unreachable", now),
            LogDecision::Emit
        );
        assert_eq!(
            limiter.record("network_unreachable", now + Duration::from_secs(1)),
            LogDecision::Suppress
        );
        assert_eq!(limiter.suppressed("network_unreachable"), 1);
        assert_eq!(
            limiter.record("network_unreachable", now + Duration::from_secs(31)),
            LogDecision::EmitSummary { suppressed: 1 }
        );
    }

    #[test]
    fn tail_is_bounded_to_requested_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("airsend.log");
        let mut writer = SizeRotatingWriter::new(path, 100, 2).unwrap();
        writer.write_all(b"abcdefgh").unwrap();
        writer.flush().unwrap();

        assert_eq!(writer.tail(4).unwrap(), "efgh");
        assert_eq!(writer.paths().unwrap().len(), 3);
    }

    #[test]
    fn clear_removes_backups_and_resets_active_cursor() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("airsend.log");
        let mut writer = SizeRotatingWriter::new(path.clone(), 100, 2).unwrap();
        writer.write_all(&[b'x'; 150]).unwrap();
        writer.flush().unwrap();
        assert!(path.with_extension("log.1").exists());

        writer.clear().unwrap();
        writer.write_all(b"new").unwrap();
        writer.flush().unwrap();

        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        assert!(!path.with_extension("log.1").exists());
        assert!(!path.with_extension("log.2").exists());
    }
}
