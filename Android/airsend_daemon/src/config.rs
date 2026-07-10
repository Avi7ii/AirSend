use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const CONFIG_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReceivePolicy {
    Ask,
    TrustedOnly,
    Off,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TransportPreference {
    Https,
    HttpCompatibility,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ManualPeer {
    pub id: String,
    pub alias: String,
    pub address: String,
    pub port: u16,
    pub fingerprint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, rename_all = "camelCase")]
pub struct AirSendConfig {
    pub version: u32,
    pub preferred_target: Option<String>,
    pub manual_peers: Vec<ManualPeer>,
    pub trusted_peer_fingerprints: Vec<String>,
    pub receive_policy: ReceivePolicy,
    pub clipboard_sync_enabled: bool,
    pub screenshot_sync_enabled: bool,
    pub startup_enabled: bool,
    pub download_destination: String,
    pub media_destination: String,
    pub transport_preference: TransportPreference,
}

impl Default for AirSendConfig {
    fn default() -> Self {
        Self {
            version: CONFIG_VERSION,
            preferred_target: None,
            manual_peers: Vec::new(),
            trusted_peer_fingerprints: Vec::new(),
            receive_policy: ReceivePolicy::Ask,
            clipboard_sync_enabled: false,
            screenshot_sync_enabled: false,
            startup_enabled: true,
            download_destination: "/sdcard/Download/AirSend".to_string(),
            media_destination: "/sdcard/Pictures/AirSend".to_string(),
            transport_preference: TransportPreference::Https,
        }
    }
}

impl AirSendConfig {
    pub fn normalized(&self) -> Result<Self> {
        if self.version != CONFIG_VERSION {
            return Err(anyhow!(
                "unsupported config version {}; expected {}",
                self.version,
                CONFIG_VERSION
            ));
        }

        validate_shared_storage_path("download_destination", &self.download_destination)?;
        validate_shared_storage_path("media_destination", &self.media_destination)?;

        let mut peers = BTreeMap::new();
        for peer in &self.manual_peers {
            let normalized = ManualPeer {
                id: required_trimmed("manual peer id", &peer.id)?,
                alias: required_trimmed("manual peer alias", &peer.alias)?,
                address: required_trimmed("manual peer address", &peer.address)?,
                port: peer.port,
                fingerprint: peer
                    .fingerprint
                    .as_deref()
                    .map(normalize_fingerprint)
                    .transpose()?,
            };
            if normalized.port == 0 {
                return Err(anyhow!("manual peer port must be greater than zero"));
            }
            let key = format!(
                "{}:{}",
                normalized.address.to_ascii_lowercase(),
                normalized.port
            );
            peers.insert(key, normalized);
        }

        let trusted_peer_fingerprints = self
            .trusted_peer_fingerprints
            .iter()
            .map(|value| normalize_fingerprint(value))
            .collect::<Result<BTreeSet<_>>>()?
            .into_iter()
            .collect();

        Ok(Self {
            version: CONFIG_VERSION,
            preferred_target: self
                .preferred_target
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string),
            manual_peers: peers.into_values().collect(),
            trusted_peer_fingerprints,
            receive_policy: self.receive_policy.clone(),
            clipboard_sync_enabled: self.clipboard_sync_enabled,
            screenshot_sync_enabled: self.screenshot_sync_enabled,
            startup_enabled: self.startup_enabled,
            download_destination: self.download_destination.trim().to_string(),
            media_destination: self.media_destination.trim().to_string(),
            transport_preference: self.transport_preference.clone(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigLoadOutcome {
    pub config: AirSendConfig,
    pub warning: Option<String>,
    pub recovered_path: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct ConfigStore {
    path: PathBuf,
}

impl ConfigStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn load(&self) -> Result<AirSendConfig> {
        if !self.path.exists() {
            return Ok(AirSendConfig::default());
        }
        let bytes = fs::read(&self.path)
            .with_context(|| format!("failed to read {}", self.path.display()))?;
        let parsed: AirSendConfig = serde_json::from_slice(&bytes)
            .with_context(|| format!("failed to parse {}", self.path.display()))?;
        parsed.normalized()
    }

    pub fn load_with_recovery(&self) -> Result<ConfigLoadOutcome> {
        match self.load() {
            Ok(config) => Ok(ConfigLoadOutcome {
                config,
                warning: None,
                recovered_path: None,
            }),
            Err(error) if self.path.exists() => {
                let recovered_path = self.corrupt_backup_path();
                fs::rename(&self.path, &recovered_path).with_context(|| {
                    format!(
                        "failed to preserve corrupt config {} as {}",
                        self.path.display(),
                        recovered_path.display()
                    )
                })?;
                Ok(ConfigLoadOutcome {
                    config: AirSendConfig::default(),
                    warning: Some(format!("config_recovered: {error:#}")),
                    recovered_path: Some(recovered_path),
                })
            }
            Err(error) => Err(error),
        }
    }

    pub fn save(&self, config: &AirSendConfig) -> Result<()> {
        let normalized = config.normalized()?;
        let parent = self
            .path
            .parent()
            .ok_or_else(|| anyhow!("config path has no parent: {}", self.path.display()))?;
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("failed to chmod {}", parent.display()))?;

        let temp_path = self.path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(&normalized)?;
        let mut temp = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&temp_path)
            .with_context(|| format!("failed to open {}", temp_path.display()))?;
        temp.write_all(&bytes)?;
        temp.write_all(b"\n")?;
        temp.sync_all()?;
        fs::set_permissions(&temp_path, fs::Permissions::from_mode(0o600))?;
        fs::rename(&temp_path, &self.path).with_context(|| {
            format!(
                "failed to atomically replace {} with {}",
                self.path.display(),
                temp_path.display()
            )
        })?;
        File::open(parent)?.sync_all()?;
        Ok(())
    }

    fn corrupt_backup_path(&self) -> PathBuf {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let file_name = self
            .path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("config");
        self.path
            .with_file_name(format!("{file_name}.corrupt.{timestamp}.json"))
    }
}

fn required_trimmed(field: &str, value: &str) -> Result<String> {
    let value = value.trim();
    if value.is_empty() {
        return Err(anyhow!("{field} must not be empty"));
    }
    Ok(value.to_string())
}

fn normalize_fingerprint(value: &str) -> Result<String> {
    Ok(required_trimmed("fingerprint", value)?.to_ascii_lowercase())
}

fn validate_shared_storage_path(field: &str, value: &str) -> Result<()> {
    let value = value.trim();
    if !Path::new(value).is_absolute()
        || !(value == "/sdcard"
            || value.starts_with("/sdcard/")
            || value == "/storage/emulated/0"
            || value.starts_with("/storage/emulated/0/")
            || value == "/data/media/0"
            || value.starts_with("/data/media/0/"))
    {
        return Err(anyhow!(
            "{field} must be an absolute primary shared-storage path"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn round_trips_valid_config_atomically() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("config.json");
        let store = ConfigStore::new(path.clone());
        let mut config = AirSendConfig {
            clipboard_sync_enabled: false,
            receive_policy: ReceivePolicy::TrustedOnly,
            ..AirSendConfig::default()
        };
        config.manual_peers.push(ManualPeer {
            id: "peer-1".to_string(),
            alias: "Desktop".to_string(),
            address: "192.168.1.5".to_string(),
            port: 53317,
            fingerprint: Some("AA:BB".to_string()),
        });

        store.save(&config).unwrap();

        assert_eq!(store.load().unwrap(), config.normalized().unwrap());
        assert!(!path.with_extension("json.tmp").exists());
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn corrupt_config_is_preserved_and_defaults_are_loaded() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("config.json");
        std::fs::write(&path, b"not-json").unwrap();

        let outcome = ConfigStore::new(path).load_with_recovery().unwrap();

        assert_eq!(outcome.config, AirSendConfig::default());
        assert!(outcome.warning.is_some());
        assert!(temp.path().read_dir().unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains("corrupt")
        }));
    }

    #[test]
    fn normalizes_duplicate_peers_and_fingerprints() {
        let mut config = AirSendConfig::default();
        config.manual_peers = vec![
            ManualPeer {
                id: "one".to_string(),
                alias: " First ".to_string(),
                address: " 192.168.1.8 ".to_string(),
                port: 53317,
                fingerprint: None,
            },
            ManualPeer {
                id: "two".to_string(),
                alias: "Second".to_string(),
                address: "192.168.1.8".to_string(),
                port: 53317,
                fingerprint: None,
            },
        ];
        config.trusted_peer_fingerprints = vec![
            " AA:BB ".to_string(),
            "aa:bb".to_string(),
            "CC:DD".to_string(),
        ];

        let normalized = config.normalized().unwrap();

        assert_eq!(normalized.manual_peers.len(), 1);
        assert_eq!(normalized.manual_peers[0].id, "two");
        assert_eq!(
            normalized.trusted_peer_fingerprints,
            vec!["aa:bb".to_string(), "cc:dd".to_string()]
        );
    }

    #[test]
    fn rejects_relative_shared_storage_destination() {
        let config = AirSendConfig {
            download_destination: "Download/AirSend".to_string(),
            ..AirSendConfig::default()
        };

        let error = config.normalized().unwrap_err();

        assert!(error.to_string().contains("download_destination"));
    }
}
