use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "lowercase")]
pub enum DeviceType {
    Mobile,
    Desktop,
    Web,
    Headless,
    Server,
    Unknown,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub alias: String,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_type: Option<DeviceType>,
    pub fingerprint: String,
    pub port: u16,
    pub protocol: String,
    #[serde(default)]
    pub download: bool,
    #[serde(default)]
    pub announce: Option<bool>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Http,
    Https,
}

impl Default for DeviceInfo {
    fn default() -> Self {
        Self {
            alias: "RustSend".to_string(),
            version: "2.1".to_string(),
            device_model: None,
            device_type: Some(DeviceType::Headless),
            fingerprint: Uuid::new_v4().to_string(),
            port: 53317,
            protocol: "https".to_string(),
            download: true,
            announce: Some(true),
        }
    }
}

impl DeviceInfo {
    pub fn to_json(&self) -> crate::error::Result<String> {
        Ok(serde_json::to_string(self)?)
    }
}
